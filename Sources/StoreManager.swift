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
    private var homeScreenMonitorTask: Task<Void, Never>?

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
        startLiveHomeScreenMonitor()
    }

    func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func installedKey(for bundleID: String) -> String {
        "installed_bundle_\(bundleID)"
    }

    // Continuously syncs with the iOS Home Screen every 1.5s while ModStore is active
    private func startLiveHomeScreenMonitor() {
        homeScreenMonitorTask?.cancel()
        homeScreenMonitorTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if UIApplication.shared.applicationState == .active && !apps.isEmpty {
                    refreshInstallStates(sendNotifications: false)
                }
            }
        }
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
            self.apps = decoded.apps
            self.modStoreMeta = decoded.modStore
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
            if isModStoreUpdateAvailable {
                modStoreInstallState = .updateAvailable
                if sendNotifications {
                    sendUpdateNotification(
                        id: "update-modstore-\(meta.version)",
                        title: "ModStore Update Available",
                        body: "ModStore v\(meta.version) is available. Tap to view in Settings.",
                        userInfo: ["target": "modstore_update"]
                    )
                }
            } else {
                modStoreInstallState = .installed
            }
        }
    }

    // MARK: - Live Home Screen Presence Check (Checks All IPA URL Schemes + Bundle ID Fallbacks)
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

    /// Returns `true` if installed on Home Screen, `false` if deleted/not installed, or `nil` if the IPA has no queryable scheme
    private func checkHomeScreenPresence(for app: ModApp) -> Bool? {
        let whitelisted = Set((Bundle.main.infoDictionary?["LSApplicationQueriesSchemes"] as? [String] ?? []).map { $0.lowercased() })
        let schemes = candidateSchemes(for: app)

        // Find every scheme belonging to this IPA that ModStore is allowed to query
        let queryable = schemes.filter { whitelisted.contains($0.lowercased()) }
        guard !queryable.isEmpty else {
            return nil
        }

        for scheme in queryable {
            if let url = URL(string: "\(scheme)://"), UIApplication.shared.canOpenURL(url) {
                return true
            }
        }
        return false
    }

    private func evaluateAppState(for app: ModApp) -> InstallState {
        let key = installedKey(for: app.bundleIdentifier)
        let savedVersion = UserDefaults.standard.string(forKey: key)

        if let isOnHomeScreen = checkHomeScreenPresence(for: app) {
            if !isOnHomeScreen {
                // App is NOT on the Home Screen (never installed or user deleted it on Home Screen)
                if savedVersion != nil {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                return .notInstalled
            } else {
                // App IS on the Home Screen right now!
                if let saved = savedVersion {
                    if app.version.compare(saved, options: .numeric) == .orderedDescending {
                        return .updateAvailable
                    }
                    return .installed
                } else {
                    // App was already on Home Screen; record current version and show OPEN
                    UserDefaults.standard.set(app.version, forKey: key)
                    return .installed
                }
            }
        }

        // Fallback for IPAs without any URL scheme in Info.plist
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

    // MARK: - 2-Phase Progress (0%->75% Server Download, 75%->100% iOS Home Screen Install)
    private func startPollingServerProgress(for app: ModApp) {
        pollTasks[app.id]?.cancel()

        let wasAlreadyOnHomeScreen = (checkHomeScreenPresence(for: app) == true)

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
                try? await Task.sleep(nanoseconds: 250_000_000) // Poll every 0.25s
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
                        // As soon as the popup closes and ModStore becomes active again, revert after 1 tick (~0.25s) if user tapped Cancel!
                        if didReturnFromPopup {
                            postPopupTicks += 1
                            if postPopupTicks >= 2 {
                                revertState(for: app)
                                return
                            }
                        }

                    case "downloading":
                        postPopupTicks = 0
                        // Phase 1: Map HTTP download progress (0.0 -> 1.0) to 5% -> 75% of the circle ring
                        let mappedProgress = 0.05 + (min(max(resp.progress, 0.0), 1.0) * 0.70)
                        installStates[app.id] = .downloading(progress: mappedProgress)

                    case "completed":
                        // Phase 2: Server finished sending bytes; iOS installd is now unpacking & installing on Home Screen (75% -> 100%)
                        let estimatedInstallSeconds = max(3.5, min(10.0, Double(app.sizeBytes) / 22_000_000.0))
                        let stepInterval = 0.2
                        let totalSteps = max(10, Int(estimatedInstallSeconds / stepInterval))

                        for step in 1...totalSteps {
                            guard !Task.isCancelled else { return }
                            try? await Task.sleep(nanoseconds: UInt64(stepInterval * 1_000_000_000))
                            guard !Task.isCancelled else { return }

                            // If fresh install and iOS just finished registering the app on the Home Screen early, finish immediately!
                            if !wasAlreadyOnHomeScreen, checkHomeScreenPresence(for: app) == true {
                                break
                            }

                            let installFraction = Double(step) / Double(totalSteps)
                            let ringProgress = 0.75 + (installFraction * 0.24)
                            installStates[app.id] = .downloading(progress: min(0.99, ringProgress))
                        }

                        // If fresh install with queryable scheme, wait up to 4 extra seconds at 99% until Home Screen icon is ready
                        if !wasAlreadyOnHomeScreen, checkHomeScreenPresence(for: app) != nil {
                            var extraWait = 0
                            while checkHomeScreenPresence(for: app) == false && extraWait < 16 && !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                extraWait += 1
                            }
                        }

                        // Complete the full 100% circle and immediately morph into OPEN!
                        installStates[app.id] = .downloading(progress: 1.0)
                        try? await Task.sleep(nanoseconds: 120_000_000)
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
        // Revert button immediately (0.0s delay)
        pollTasks[app.id]?.cancel()
        pollTasks.removeValue(forKey: app.id)
        revertState(for: app)

        if let cancelURL = URL(string: "\(cleanBaseURL)/cancel/\(app.id)") {
            Task {
                let req = URLRequest(url: cancelURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }

    func openAppByBundleID(_ app: ModApp) {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else {
            return
        }

        let selector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: selector) else { return }

        typealias OpenBundleIDFunc = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let imp = workspace.method(for: selector)
        let openFunc = unsafeBitCast(imp, to: OpenBundleIDFunc.self)
        let didLaunch = openFunc(workspace, selector, app.bundleIdentifier as NSString)

        if !didLaunch {
            UserDefaults.standard.removeObject(forKey: installedKey(for: app.bundleIdentifier))
            installStates[app.id] = .notInstalled
            showBanner("\(app.name) is no longer installed on the Home Screen.", isError: true)
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