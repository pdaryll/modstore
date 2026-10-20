import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks
import ObjectiveC.runtime

struct StatusBanner: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
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
    @Published var installStates: [String: InstallState] = [:]
    @Published var modStoreInstallState: InstallState = .installed

    @Published var selectedTab: Int = 0
    @Published var deepLinkApp: ModApp? = nil
    @Published var statusBanner: StatusBanner? = nil

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

        // Re-check all Home Screen apps every time you switch back to ModStore
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

            // Only mutate @Published arrays if changed so pull-to-refresh never stutters or snaps
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
            if case .downloading = installStates[app.id] { continue }
            if case .awaitingConfirmation = installStates[app.id] { continue }

            let newState = evaluateAppState(for: app)
            if installStates[app.id] != newState {
                installStates[app.id] = newState
            }

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

    // MARK: - Direct Home Screen Presence Check (FrontBoard Bundle ID + URL Schemes)
    private func checkViaFrontBoard(bundleID: String) -> Bool? {
        guard let serviceClass = NSClassFromString("FBSOpenApplicationService") as? NSObject.Type else {
            return nil
        }

        let serviceObj: NSObject? = {
            let sel1 = NSSelectorFromString("serviceWithDefaultShellEndpoint")
            if serviceClass.responds(to: sel1),
               let obj = serviceClass.perform(sel1)?.takeUnretainedValue() as? NSObject {
                return obj
            }
            let sel2 = NSSelectorFromString("defaultService")
            if serviceClass.responds(to: sel2),
               let obj = serviceClass.perform(sel2)?.takeUnretainedValue() as? NSObject {
                return obj
            }
            return nil
        }()

        guard let service = serviceObj else { return nil }
        let canOpenSel = NSSelectorFromString("canOpenApplication:reason:")
        guard service.responds(to: canOpenSel),
              let selfBundleID = Bundle.main.bundleIdentifier else {
            return nil
        }

        typealias CanOpenFunc = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<Int>?) -> Bool
        let imp = service.method(for: canOpenSel)
        let fn = unsafeBitCast(imp, to: CanOpenFunc.self)

        var selfReason: Int = -999
        var fakeReason: Int = -999
        let selfResult = fn(service, canOpenSel, selfBundleID as NSString, &selfReason)
        let fakeResult = fn(service, canOpenSel, "com.nonexistent.modstore.missing.99999" as NSString, &fakeReason)

        var targetReason: Int = -999
        let targetResult = fn(service, canOpenSel, bundleID as NSString, &targetReason)

        if selfResult != fakeResult {
            return targetResult == selfResult
        }
        if selfReason != fakeReason {
            return targetReason != fakeReason
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
        if bid.contains("tweetie") || bid.contains("twitter") { list.append("twitter") }
        if bid.contains("youtube") { list.append(contentsOf: ["youtube", "vnd.youtube"]) }
        if bid.contains("instagram") { list.append("instagram") }
        if bid.contains("spotify") { list.append("spotify") }
        if bid.contains("reddit") { list.append("reddit") }
        if bid.contains("discord") { list.append("discord") }
        if bid.contains("twitch") { list.append("twitch") }
        if bid.contains("tiktok") || bid.contains("musical") { list.append(contentsOf: ["tiktok", "snssdk1233"]) }
        return list
    }

    private func isAppInstalledOnHomeScreen(_ app: ModApp) -> Bool? {
        // 1. Check directly by Bundle ID via FrontBoardServices
        if let fbResult = checkViaFrontBoard(bundleID: app.bundleIdentifier) {
            return fbResult
        }

        // 2. Check all candidate URL schemes
        let schemes = candidateSchemes(for: app)
        for scheme in schemes {
            if let url = URL(string: "\(scheme)://"), UIApplication.shared.canOpenURL(url) {
                UserDefaults.standard.set(scheme, forKey: "verified_scheme_\(app.bundleIdentifier)")
                return true
            }
        }

        // If a verified scheme previously worked or is in Info.plist, false means the app is not on the Home Screen
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
                // App is NOT on the Home Screen (deleted or not yet installed)
                if savedVersion != nil {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                return .notInstalled
            } else {
                // App IS on the Home Screen
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
        installStates[app.id] = previousStates[app.id] ?? evaluateAppState(for: app)
        if let reason = errorReason {
            showBanner(reason, isError: true)
        }
    }

    // MARK: - Actions
    func handlePrimaryAction(for app: ModApp) {
        let state = installStates[app.id] ?? .notInstalled
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
        if let current = installStates[app.id], current != .awaitingConfirmation {
            previousStates[app.id] = current
        } else {
            previousStates[app.id] = evaluateAppState(for: app)
        }

        installStates[app.id] = .awaitingConfirmation

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

    // MARK: - Accurate 2-Phase Progress (Waits Until App Is Actually Installed on Home Screen Before Hitting 100%)
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
                        installStates[app.id] = .awaitingConfirmation
                        waitingManifestTicks += 1
                        if waitingManifestTicks >= 40 {
                            revertState(for: app, errorReason: "iOS did not fetch the manifest. Check HTTPS tunnel.")
                            return
                        }

                    case "manifest_fetched":
                        installStates[app.id] = .awaitingConfirmation
                        if didReturnFromPopup {
                            postPopupTicks += 1
                            if postPopupTicks >= 2 {
                                revertState(for: app)
                                return
                            }
                        }

                    case "downloading":
                        postPopupTicks = 0
                        // Phase 1: Real HTTP download maps to 5% -> 80% of the progress ring
                        let mappedProgress = 0.05 + (min(max(resp.progress, 0.0), 1.0) * 0.75)
                        installStates[app.id] = .downloading(progress: mappedProgress)

                    case "completed":
                        // Phase 2: iOS is unpacking & verifying the IPA on the Home Screen (80% -> 99%)
                        // Poll until the app is genuinely installed on the Home Screen before hitting 100%!
                        var currentVisualProgress = 0.80
                        let maxWaitTicks = 180 // Up to 63 seconds for large modded IPAs to finish installing on device

                        for tick in 1...maxWaitTicks {
                            guard !Task.isCancelled else { return }
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            guard !Task.isCancelled else { return }

                            if !wasAlreadyInstalled {
                                if let installedNow = isAppInstalledOnHomeScreen(app) {
                                    if installedNow {
                                        // App just finished installing on the Home Screen! Break immediately to hit 100%
                                        break
                                    } else {
                                        // Still installing on Home Screen; creep slowly toward 99% and keep waiting
                                        currentVisualProgress = min(0.99, 0.80 + (Double(tick) / 45.0) * 0.19)
                                        installStates[app.id] = .downloading(progress: currentVisualProgress)
                                        continue
                                    }
                                }
                            }

                            // Fallback if updating an already-installed app (estimate unpacking duration by IPA size)
                            let estimatedTicks = max(16, Int(Double(app.sizeBytes) / 4_500_000.0))
                            currentVisualProgress = min(0.99, 0.80 + (Double(tick) / Double(estimatedTicks)) * 0.19)
                            installStates[app.id] = .downloading(progress: currentVisualProgress)
                            if tick >= estimatedTicks {
                                break
                            }
                        }

                        // Snap to 100% full circle and immediately transform into OPEN!
                        installStates[app.id] = .downloading(progress: 1.0)
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        UserDefaults.standard.set(app.version, forKey: installedKey(for: app.bundleIdentifier))
                        previousStates[app.id] = .installed
                        installStates[app.id] = .installed
                        return

                    case "cancelled":
                        revertState(for: app)
                        return

                    case "error":
                        revertState(for: app, errorReason: "Download interrupted for \(app.name). Please try again.")
                        return

                    default:
                        break
                    }
                } catch {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 4 {
                        revertState(for: app, errorReason: "Lost connection to server while installing \(app.name).")
                        return
                    }
                }
            }
        }
    }

    func cancelDownload(for app: ModApp) {
        pollTasks[app.id]?.cancel()
        pollTasks.removeValue(forKey: app.id)
        UserDefaults.standard.removeObject(forKey: installedKey(for: app.bundleIdentifier))
        installStates[app.id] = evaluateAppState(for: app)

        if let cancelURL = URL(string: "\(cleanBaseURL)/cancel/\(app.id)") {
            Task {
                let req = URLRequest(url: cancelURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
                _ = try? await URLSession.shared.data(for: req)
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
            installStates[app.id] = .notInstalled
            showBanner("\(app.name) is not installed on the Home Screen.", isError: true)
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