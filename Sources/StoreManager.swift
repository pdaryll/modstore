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
    @Published var appPendingDeletion: ModApp? = nil
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
    }

    func requestPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func installedKey(for bundleID: String) -> String {
        "installed_bundle_\(bundleID)"
    }

    private func schemeVerifiedKey(for bundleID: String) -> String {
        "scheme_verified_\(bundleID)"
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
            try? await Task.sleep(nanoseconds: 3_800_000_000)
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

            let state = evaluateAppState(for: app)
            installStates[app.id] = state

            if sendNotifications && state == .updateAvailable {
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

    // MARK: - Automatic Home Screen Uninstall Detection
    private func isAppStillOnHomeScreen(_ app: ModApp) -> Bool {
        // 1. Check LSApplicationWorkspace.applicationIsInstalled: if supported by OS profile
        if let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
           let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject {
            let selector = NSSelectorFromString("applicationIsInstalled:")
            if workspace.responds(to: selector),
               let selfBundle = Bundle.main.bundleIdentifier {
                typealias IsInstalledFunc = @convention(c) (AnyObject, Selector, NSString) -> Bool
                let imp = workspace.method(for: selector)
                let checkFunc = unsafeBitCast(imp, to: IsInstalledFunc.self)
                // Only trust applicationIsInstalled: if it returns true for ModStore itself
                if checkFunc(workspace, selector, selfBundle as NSString) {
                    return checkFunc(workspace, selector, app.bundleIdentifier as NSString)
                }
            }
        }

        // 2. Check URL Scheme via canOpenURL (if scheme is in Info.plist or previously verified)
        let candidateScheme = resolvedURLScheme(for: app)
        if !candidateScheme.isEmpty,
           let schemeURL = URL(string: "\(candidateScheme)://") {
            let queriedSchemes = (Bundle.main.infoDictionary?["LSApplicationQueriesSchemes"] as? [String] ?? []).map { $0.lowercased() }
            let wasVerified = UserDefaults.standard.bool(forKey: schemeVerifiedKey(for: app.bundleIdentifier))

            if queriedSchemes.contains(candidateScheme.lowercased()) || wasVerified {
                let canOpen = UIApplication.shared.canOpenURL(schemeURL)
                if canOpen {
                    UserDefaults.standard.set(true, forKey: schemeVerifiedKey(for: app.bundleIdentifier))
                }
                return canOpen
            } else if UIApplication.shared.canOpenURL(schemeURL) {
                UserDefaults.standard.set(true, forKey: schemeVerifiedKey(for: app.bundleIdentifier))
                return true
            }
        }

        return true
    }

    private func resolvedURLScheme(for app: ModApp) -> String {
        if !app.urlScheme.isEmpty { return app.urlScheme }
        let bid = app.bundleIdentifier.lowercased()
        if bid.contains("tweetie") || bid.contains("twitter") { return "twitter" }
        if bid.contains("youtube") { return "youtube" }
        if bid.contains("instagram") { return "instagram" }
        if bid.contains("spotify") { return "spotify" }
        if bid.contains("reddit") { return "reddit" }
        if bid.contains("discord") { return "discord" }
        if bid.contains("twitch") { return "twitch" }
        return ""
    }

    private func evaluateAppState(for app: ModApp) -> InstallState {
        guard let savedVersion = UserDefaults.standard.string(forKey: installedKey(for: app.bundleIdentifier)) else {
            return .notInstalled
        }

        // Verify the app wasn't deleted from the Home Screen
        if !isAppStillOnHomeScreen(app) {
            UserDefaults.standard.removeObject(forKey: installedKey(for: app.bundleIdentifier))
            return .notInstalled
        }

        if app.version.compare(savedVersion, options: .numeric) == .orderedDescending {
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

    // MARK: - Primary Actions & Delete Flow with Spinner
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

    func requestDeleteApp(_ app: ModApp) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        appPendingDeletion = app
    }

    func confirmDeleteApp(_ app: ModApp) {
        pollTasks[app.id]?.cancel()
        pollTasks.removeValue(forKey: app.id)

        // 1. Morph button into spinning ring while deleting
        installStates[app.id] = .awaitingConfirmation

        Task { @MainActor in
            var didSystemUninstall = false
            if let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
               let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject {
                let selector = NSSelectorFromString("uninstallApplication:withOptions:")
                if workspace.responds(to: selector) {
                    typealias UninstallFunc = @convention(c) (AnyObject, Selector, NSString, AnyObject?) -> Bool
                    let imp = workspace.method(for: selector)
                    let uninstall = unsafeBitCast(imp, to: UninstallFunc.self)
                    didSystemUninstall = uninstall(workspace, selector, app.bundleIdentifier as NSString, nil)
                }
            }

            // Let the loading spinner run smoothly before morphing into INSTALL
            try? await Task.sleep(nanoseconds: 750_000_000)

            UserDefaults.standard.removeObject(forKey: installedKey(for: app.bundleIdentifier))
            UserDefaults.standard.removeObject(forKey: schemeVerifiedKey(for: app.bundleIdentifier))
            previousStates.removeValue(forKey: app.id)

            // 2. Morph spinner into INSTALL button
            installStates[app.id] = .notInstalled

            if !didSystemUninstall {
                showBanner("\(app.name) removed from ModStore. Remove icon on Home Screen if still present.", isError: false)
            }
        }
    }

    // MARK: - OTA Install with Cache-Busting & Error Notification
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

            // Always use cleanBaseURL so a localhost catalog.json never breaks OTA installs
            let ts = Int(Date().timeIntervalSince1970)
            let rawManifestURL = "\(cleanBaseURL)/manifests/\(app.id).plist?t=\(ts)"

            // Strictly encode ':', '/', '?', '=', and '&' for itms-services query parameter
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
                try? await Task.sleep(nanoseconds: 300_000_000) // Poll every 0.3s
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
                        // Give iOS up to 10 seconds (33 ticks) to fetch /manifests/<app>.plist
                        if waitingManifestTicks >= 33 {
                            revertState(for: app, errorReason: "iOS did not fetch the manifest. Make sure your server URL uses HTTPS.")
                            return
                        }

                    case "manifest_fetched":
                        // Popup is currently on screen! Keep spinning until user taps Install or Cancel
                        installStates[app.id] = .awaitingConfirmation
                        if didReturnFromPopup {
                            postPopupTicks += 1
                            // Wait ~2.4s (8 ticks) after popup closes; if download hasn't started, user tapped Cancel
                            if postPopupTicks >= 8 {
                                revertState(for: app)
                                return
                            }
                        }

                    case "downloading":
                        postPopupTicks = 0
                        installStates[app.id] = .downloading(progress: max(0.05, resp.progress))

                    case "completed":
                        installStates[app.id] = .downloading(progress: 1.0)
                        try? await Task.sleep(nanoseconds: 3_200_000_000)
                        UserDefaults.standard.set(app.version, forKey: installedKey(for: app.bundleIdentifier))
                        let scheme = resolvedURLScheme(for: app)
                        if !scheme.isEmpty, let sURL = URL(string: "\(scheme)://"), UIApplication.shared.canOpenURL(sURL) {
                            UserDefaults.standard.set(true, forKey: schemeVerifiedKey(for: app.bundleIdentifier))
                        }
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
            showBanner("\(app.name) is no longer installed.", isError: true)
        }
    }

    func installModStoreUpdate() {
        guard let meta = modStoreMeta else { return }
        let encoded = meta.manifestURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? meta.manifestURL
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