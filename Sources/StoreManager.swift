import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks
import ObjectiveC.runtime
import Darwin

struct StatusBanner: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

// Isolated per-app state object so progress ticks ONLY redraw the 30x30 button, NEVER the List or NavigationStack!
@MainActor
final class AppInstallStateHolder: ObservableObject {
    @Published var state: InstallState = .notInstalled
}

@MainActor
final class StoreManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = StoreManager()
    static let bgTaskID = "com.daryll.modstore.refresh"

    @Published var serverBaseURL: String = UserDefaults.standard.string(forKey: "serverBaseURL") ?? "https://store.daryll.site" {
        didSet {
            UserDefaults.standard.set(serverBaseURL, forKey: "serverBaseURL")
        }
    }

    var cleanBaseURL: String {
        var cleaned = serverBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleaned.hasSuffix("/catalog.json") {
            cleaned = String(cleaned.dropLast("/catalog.json".count))
        }
        return cleaned
    }

    var catalogURL: URL {
        URL(string: "\(cleanBaseURL)/catalog.json") ?? URL(string: "https://localhost/catalog.json")!
    }

    @Published var apps: [ModApp] = []
    @Published var modStoreMeta: ModStoreMeta?
    @Published var modStoreInstallState: InstallState = .installed

    @Published var selectedTab: Int = 0
    @Published var deepLinkApp: ModApp? = nil
    @Published var statusBanner: StatusBanner? = nil

    // Non-@Published dictionary of per-app state holders so progress updates never invalidate CatalogListView
    private var stateHolders: [String: AppInstallStateHolder] = [:]
    private var pendingDeepLinkAppID: String?
    private var pollTasks: [String: Task<Void, Never>] = [:]
    private var previousStates: [String: InstallState] = [:]
    private var bannerTask: Task<Void, Never>?

    var currentModStoreVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var isModStoreUpdateAvailable: Bool {
        guard let remoteVersion = modStoreMeta?.version else { return false }
        return remoteVersion.compare(currentModStoreVersion, options: .numeric) == .orderedDescending
    }

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshInstallStates(sendNotifications: false)
            }
        }
    }

    func stateHolder(for appID: String) -> AppInstallStateHolder {
        if let existing = stateHolders[appID] {
            return existing
        }
        let holder = AppInstallStateHolder()
        if let app = apps.first(where: { $0.id == appID }) {
            holder.state = evaluateAppState(for: app)
        }
        stateHolders[appID] = holder
        return holder
    }

    func currentState(for appID: String) -> InstallState {
        stateHolder(for: appID).state
    }

    private func setState(_ newState: InstallState, for appID: String) {
        let holder = stateHolder(for: appID)
        if holder.state != newState {
            holder.state = newState
        }
    }

    func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func installedKey(for bundleID: String) -> String {
        "installed_bundle_\(bundleID)"
    }

    func showBanner(_ message: String, isError: Bool = true) {
        if isError {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            statusBanner = StatusBanner(message: message, isError: isError)
        }
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                statusBanner = nil
            }
        }
    }

    func fetchCatalog(sendNotifications: Bool = false) async {
        do {
            let request = URLRequest(url: catalogURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)

            if self.apps != decoded.apps {
                self.apps = decoded.apps
            }
            if self.modStoreMeta != decoded.modStore {
                self.modStoreMeta = decoded.modStore
            }

            refreshInstallStates(sendNotifications: sendNotifications)

            if let pendingID = pendingDeepLinkAppID,
               let targetApp = apps.first(where: { $0.id == pendingID }) {
                pendingDeepLinkAppID = nil
                selectedTab = 0
                deepLinkApp = targetApp
            }
        } catch {
            print("Failed to fetch catalog: \(error)")
        }
    }

    func refreshInstallStates(sendNotifications: Bool = false) {
        for app in apps {
            let current = currentState(for: app.id)
            if case .downloading = current { continue }
            if case .awaitingConfirmation = current { continue }

            let newState = evaluateAppState(for: app)
            setState(newState, for: app.id)

            if sendNotifications && newState == .updateAvailable {
                sendUpdateNotification(
                    id: "update-\(app.bundleIdentifier)-\(app.version)",
                    title: "Update Available",
                    body: "\(app.name) v\(app.version) is ready to install.",
                    userInfo: ["target": "app_detail", "appID": app.id]
                )
            }
        }

        if let meta = modStoreMeta {
            let nextModStoreState: InstallState = isModStoreUpdateAvailable ? .updateAvailable : .installed
            if modStoreInstallState != nextModStoreState {
                modStoreInstallState = nextModStoreState
            }
            if sendNotifications && isModStoreUpdateAvailable {
                sendUpdateNotification(
                    id: "update-modstore-\(meta.version)",
                    title: "ModStore Update Available",
                    body: "ModStore v\(meta.version) is available. Tap to view in Settings.",
                    userInfo: ["target": "modstore_update"]
                )
            }
        }
    }

    // MARK: - Native iOS Install Progress Object (LSApplicationWorkspace)
    private func systemInstallProgress(for bundleID: String) -> Progress? {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let ws = wsClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        let sel = NSSelectorFromString("installProgressForBundleID:makeSynchronous:")
        guard ws.responds(to: sel) else { return nil }

        typealias InstallProgFunc = @convention(c) (AnyObject, Selector, NSString, UInt8) -> AnyObject?
        let imp = ws.method(for: sel)
        let fn = unsafeBitCast(imp, to: InstallProgFunc.self)
        return fn(ws, sel, bundleID as NSString, 0) as? Progress
    }

    // MARK: - Home Screen Presence Detection
    private func checkViaWorkspaceCalibratedWithSafari(bundleID: String) -> Bool? {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let ws = wsClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        let sel = NSSelectorFromString("applicationIsInstalled:")
        guard ws.responds(to: sel) else { return nil }

        typealias IsInstalledFunc = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let imp = ws.method(for: sel)
        let fn = unsafeBitCast(imp, to: IsInstalledFunc.self)

        let safariInstalled = fn(ws, sel, "com.apple.mobilesafari" as NSString)
        let fakeInstalled = fn(ws, sel, "com.nonexistent.fake.app.99999" as NSString)
        if safariInstalled && !fakeInstalled {
            return fn(ws, sel, bundleID as NSString)
        }
        return nil
    }

    private func candidateSchemes(for app: ModApp) -> [String] {
        var list: [String] = []
        if let ipaSchemes = app.urlSchemes {
            list.append(contentsOf: ipaSchemes)
        }
        if !app.urlScheme.isEmpty && !list.contains(app.urlScheme) {
            list.append(app.urlScheme)
        }
        let bid = app.bundleIdentifier.lowercased()
        if bid.contains("tweetie") || bid.contains("twitter") {
            list.append(contentsOf: ["twitter", "twitterauth", "atebits", "bhtwitter"])
        }
        if bid.contains("youtube") { list.append(contentsOf: ["youtube", "vnd.youtube"]) }
        if bid.contains("instagram") { list.append(contentsOf: ["instagram", "instagram-stories"]) }
        if bid.contains("spotify") { list.append("spotify") }
        if bid.contains("reddit") { list.append("reddit") }
        if bid.contains("discord") { list.append("discord") }
        if bid.contains("twitch") { list.append("twitch") }
        if bid.contains("tiktok") || bid.contains("musical") {
            list.append(contentsOf: ["tiktok", "snssdk1233", "snssdk1180", "musically"])
        }
        return list
    }

    private func isAppInstalledOnHomeScreen(_ app: ModApp) -> Bool? {
        if let prog = systemInstallProgress(for: app.bundleIdentifier),
           !prog.isFinished && !prog.isCancelled && prog.fractionCompleted > 0.0 && prog.fractionCompleted < 1.0 {
            return false
        }

        if let wsResult = checkViaWorkspaceCalibratedWithSafari(bundleID: app.bundleIdentifier) {
            return wsResult
        }

        let schemes = candidateSchemes(for: app)
        for scheme in schemes {
            if let url = URL(string: "\(scheme)://"), UIApplication.shared.canOpenURL(url) {
                UserDefaults.standard.set(scheme, forKey: "verified_scheme_\(app.bundleIdentifier)")
                return true
            }
        }

        let whitelisted = Set((Bundle.main.infoDictionary?["LSApplicationQueriesSchemes"] as? [String] ?? []).map { $0.lowercased() })
        let hasVerifiedScheme = UserDefaults.standard.string(forKey: "verified_scheme_\(app.bundleIdentifier)") != nil
        if hasVerifiedScheme || schemes.contains(where: { whitelisted.contains($0.lowercased()) }) {
            return false
        }

        return nil
    }

    private func evaluateAppState(for app: ModApp) -> InstallState {
        let key = installedKey(for: app.bundleIdentifier)
        let savedVersion = UserDefaults.standard.string(forKey: key)

        if let isOnHomeScreen = isAppInstalledOnHomeScreen(app) {
            if !isOnHomeScreen {
                if savedVersion != nil {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                return .notInstalled
            } else {
                if let saved = savedVersion {
                    if app.version.compare(saved, options: .numeric) == .orderedDescending {
                        return .updateAvailable
                    }
                    return .installed
                } else {
                    UserDefaults.standard.set(app.version, forKey: key)
                    return .installed
                }
            }
        }

        guard let saved = savedVersion else {
            return .notInstalled
        }
        if app.version.compare(saved, options: .numeric) == .orderedDescending {
            return .updateAvailable
        }
        return .installed
    }

    private func revertState(for app: ModApp, errorReason: String? = nil) {
        let fallback = previousStates[app.id] ?? evaluateAppState(for: app)
        setState(fallback, for: app.id)
        if let reason = errorReason {
            showBanner(reason, isError: true)
        }
    }

    // MARK: - Actions
    func handlePrimaryAction(for app: ModApp) {
        let state = currentState(for: app.id)
        switch state {
        case .installed:
            openAppByBundleID(app)
        case .notInstalled, .updateAvailable:
            startOTAInstall(for: app)
        default:
            break
        }
    }

    func reinstallApp(_ app: ModApp) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        startOTAInstall(for: app)
    }

    func startOTAInstall(for app: ModApp) {
        let current = currentState(for: app.id)
        if current != .awaitingConfirmation {
            previousStates[app.id] = current
        } else {
            previousStates[app.id] = evaluateAppState(for: app)
        }

        setState(.awaitingConfirmation, for: app.id)

        Task {
            if let startURL = URL(string: "\(cleanBaseURL)/start/\(app.id)") {
                let req = URLRequest(url: startURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
                _ = try? await URLSession.shared.data(for: req)
            }

            let ts = Int(Date().timeIntervalSince1970)
            let rawManifestURL = "\(cleanBaseURL)/manifests/\(app.id).plist?t=\(ts)"
            let strictAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encodedManifest = rawManifestURL.addingPercentEncoding(withAllowedCharacters: strictAllowed) ?? rawManifestURL

            guard let otaURL = URL(string: "itms-services://?action=download-manifest&url=\(encodedManifest)") else {
                revertState(for: app, errorReason: "Invalid manifest URL for \(app.name).")
                return
            }

            let opened = await UIApplication.shared.open(otaURL)
            if !opened {
                revertState(for: app, errorReason: "Could not launch iOS installer for \(app.name).")
                return
            }

            startPollingServerProgress(for: app)
        }
    }

    private func startPollingServerProgress(for app: ModApp) {
        pollTasks[app.id]?.cancel()

        let wasAlreadyInstalled = (isAppInstalledOnHomeScreen(app) == true)

        pollTasks[app.id] = Task { @MainActor in
            guard let progressURL = URL(string: "\(cleanBaseURL)/progress/\(app.id)") else {
                revertState(for: app, errorReason: "Could not connect to server.")
                return
            }

            var didReturnFromPopup = false
            let observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                didReturnFromPopup = true
            }
            defer {
                NotificationCenter.default.removeObserver(observer)
            }

            var waitingManifestTicks = 0
            var postPopupTicks = 0
            var consecutiveErrors = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { break }

                do {
                    let req = URLRequest(url: progressURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 4)
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let resp = try JSONDecoder().decode(ProgressResponse.self, from: data)
                    consecutiveErrors = 0

                    switch resp.status {
                    case "waiting_manifest", "waiting", "idle":
                        setState(.awaitingConfirmation, for: app.id)
                        waitingManifestTicks += 1
                        if waitingManifestTicks >= 40 {
                            revertState(for: app, errorReason: "iOS did not fetch the manifest. Check HTTPS tunnel.")
                            return
                        }

                    case "manifest_fetched":
                        setState(.awaitingConfirmation, for: app.id)
                        if didReturnFromPopup {
                            postPopupTicks += 1
                            if postPopupTicks >= 4 {
                                revertState(for: app)
                                return
                            }
                        }

                    case "downloading":
                        postPopupTicks = 0
                        if let sysProg = systemInstallProgress(for: app.bundleIdentifier), sysProg.fractionCompleted > 0.01 {
                            setState(.downloading(progress: max(0.05, min(0.98, sysProg.fractionCompleted))), for: app.id)
                        } else {
                            let mappedProgress = 0.05 + (min(max(resp.progress, 0.0), 1.0) * 0.67)
                            setState(.downloading(progress: mappedProgress), for: app.id)
                        }

                    case "completed":
                        var currentVisualProgress = 0.72
                        let maxWaitTicks = 240
                        let minUnpackTicks = max(18, Int(Double(app.sizeBytes) / 3_500_000.0))

                        for tick in 1...maxWaitTicks {
                            guard !Task.isCancelled else { return }
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            guard !Task.isCancelled else { return }

                            if let sysProg = systemInstallProgress(for: app.bundleIdentifier), sysProg.fractionCompleted > 0.0 {
                                if sysProg.isFinished || sysProg.fractionCompleted >= 1.0 {
                                    break
                                }
                                currentVisualProgress = max(currentVisualProgress, min(0.99, sysProg.fractionCompleted))
                                setState(.downloading(progress: currentVisualProgress), for: app.id)
                                continue
                            }

                            if !wasAlreadyInstalled, let installedNow = isAppInstalledOnHomeScreen(app) {
                                if installedNow {
                                    break
                                } else {
                                    currentVisualProgress = min(0.98, 0.72 + (Double(tick) / Double(minUnpackTicks + 25)) * 0.26)
                                    setState(.downloading(progress: currentVisualProgress), for: app.id)
                                    continue
                                }
                            }

                            currentVisualProgress = min(0.99, 0.72 + (Double(tick) / Double(minUnpackTicks)) * 0.27)
                            setState(.downloading(progress: currentVisualProgress), for: app.id)
                            if tick >= minUnpackTicks && isAppInstalledOnHomeScreen(app) != false {
                                break
                            }
                        }

                        setState(.downloading(progress: 1.0), for: app.id)
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        UserDefaults.standard.set(app.version, forKey: installedKey(for: app.bundleIdentifier))
                        previousStates[app.id] = .installed
                        setState(.installed, for: app.id)
                        return

                    case "cancelled":
                        revertState(for: app)
                        return

                    default:
                        break
                    }
                } catch {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 6 {
                        revertState(for: app)
                        return
                    }
                }
            }
        }
    }

    // MARK: - Instant Cancel Download (Server TCP RST + Empty ZIP + Native iOS Coordinator Cancel)
    func cancelDownload(for app: ModApp) {
        pollTasks[app.id]?.cancel()
        pollTasks.removeValue(forKey: app.id)

        // 1. Revert ModStore UI state immediately
        setState(evaluateAppState(for: app), for: app.id)

        // 2. Tell server to fire TCP RST + serve 22-byte Empty ZIP so installd aborts immediately
        if let cancelURL = URL(string: "\(cleanBaseURL)/cancel/\(app.id)") {
            Task {
                let req = URLRequest(url: cancelURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
                _ = try? await URLSession.shared.data(for: req)
            }
        }

        // 3. Also invoke native iOS NSProgress / InstallCoordination cancel selectors if available
        if let sysProg = systemInstallProgress(for: app.bundleIdentifier) {
            sysProg.cancel()
        }
        if let wsClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
           let ws = wsClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject {
            for selName in ["_LSPrivateCancelInstallForBundleID:", "removeInstallProgressForBundleID:"] {
                let sel = NSSelectorFromString(selName)
                if ws.responds(to: sel) {
                    ws.perform(sel, with: app.bundleIdentifier as NSString)
                }
            }
        }
    }

    func openAppByBundleID(_ app: ModApp) {
        var didLaunch = false
        if let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
           let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject {
            let selector = NSSelectorFromString("openApplicationWithBundleID:")
            if workspace.responds(to: selector) {
                typealias OpenBundleIDFunc = @convention(c) (AnyObject, Selector, NSString) -> Bool
                let imp = workspace.method(for: selector)
                let openFunc = unsafeBitCast(imp, to: OpenBundleIDFunc.self)
                didLaunch = openFunc(workspace, selector, app.bundleIdentifier as NSString)
            }
        }

        if !didLaunch {
            UserDefaults.standard.removeObject(forKey: installedKey(for: app.bundleIdentifier))
            setState(.notInstalled, for: app.id)
            showBanner("\(app.name) is still installing or not on the Home Screen.", isError: true)
        }
    }

    func installModStoreUpdate() {
        guard let meta = modStoreMeta else { return }
        let strictAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = meta.manifestURL.addingPercentEncoding(withAllowedCharacters: strictAllowed) ?? meta.manifestURL
        guard let otaURL = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else { return }
        UIApplication.shared.open(otaURL)
    }

    private func sendUpdateNotification(id: String, title: String, body: String, userInfo: [AnyHashable: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let target = userInfo["target"] as? String
        let appID = userInfo["appID"] as? String

        Task { @MainActor in
            if target == "modstore_update" {
                self.selectedTab = 1
            } else if target == "app_detail", let appID = appID {
                self.selectedTab = 0
                if let matchingApp = self.apps.first(where: { $0.id == appID }) {
                    self.deepLinkApp = matchingApp
                } else {
                    self.pendingDeepLinkAppID = appID
                }
            }
        }
        completionHandler()
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}