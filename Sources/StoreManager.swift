import SwiftUI
import UserNotifications
import BackgroundTasks
import ObjectiveC.runtime

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
        serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
    private var pendingDeepLinkAppID: String?

    private var pollTasks: [String: Task<Void, Never>] = [:]

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

    private func evaluateAppState(for app: ModApp) -> InstallState {
        guard let savedVersion = UserDefaults.standard.string(forKey: installedKey(for: app.bundleIdentifier)) else {
            return .notInstalled
        }
        if app.version.compare(savedVersion, options: .numeric) == .orderedDescending {
            return .updateAvailable
        }
        return .installed
    }

    // MARK: - Install / Cancel / Open Actions
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

    func startOTAInstall(for app: ModApp) {
        installStates[app.id] = .awaitingConfirmation

        Task {
            // 1. Tell the server to reset the progress state for this app first
            if let startURL = URL(string: "\(cleanBaseURL)/start/\(app.id)") {
                let req = URLRequest(url: startURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
                _ = try? await URLSession.shared.data(for: req)
            }

            // 2. Trigger the native iOS "would like to install" modal
            let encodedManifest = app.manifestURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? app.manifestURL
            guard let otaURL = URL(string: "itms-services://?action=download-manifest&url=\(encodedManifest)") else {
                installStates[app.id] = evaluateAppState(for: app)
                return
            }

            let opened = await UIApplication.shared.open(otaURL)
            if !opened {
                installStates[app.id] = evaluateAppState(for: app)
                return
            }

            startPollingServerProgress(for: app)
        }
    }

    private func startPollingServerProgress(for app: ModApp) {
        pollTasks[app.id]?.cancel()

        pollTasks[app.id] = Task { @MainActor in
            guard let progressURL = URL(string: "\(cleanBaseURL)/progress/\(app.id)") else { return }

            var sawSystemAlert = false
            var postAlertActiveTicks = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000) // Poll every 0.4s
                guard !Task.isCancelled else { break }

                // Detect when the iOS "Install / Cancel" modal overlays the app (.inactive)
                if UIApplication.shared.applicationState != .active {
                    sawSystemAlert = true
                }

                do {
                    let req = URLRequest(url: progressURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let resp = try JSONDecoder().decode(ProgressResponse.self, from: data)

                    switch resp.status {
                    case "waiting", "idle":
                        installStates[app.id] = .awaitingConfirmation

                        // Only count timeout ticks AFTER the user has dismissed the system alert
                        // Gives iOS installd ~14 seconds (35 * 0.4s) after tapping "Install" to request the .ipa
                        if sawSystemAlert && UIApplication.shared.applicationState == .active {
                            postAlertActiveTicks += 1
                            if postAlertActiveTicks > 35 {
                                // User tapped "Cancel" on the iOS modal (installd never requested the IPA)
                                installStates[app.id] = evaluateAppState(for: app)
                                return
                            }
                        }

                    case "downloading":
                        // iOS installd is actively downloading the IPA: show circular ring + stop square
                        postAlertActiveTicks = 0
                        installStates[app.id] = .downloading(progress: max(0.05, resp.progress))

                    case "completed":
                        // 100% downloaded; keep ring at 100% for 4s while iOS finishes installing on Home Screen
                        installStates[app.id] = .downloading(progress: 1.0)
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        UserDefaults.standard.set(app.version, forKey: installedKey(for: app.bundleIdentifier))
                        installStates[app.id] = .installed
                        return

                    case "cancelled":
                        installStates[app.id] = evaluateAppState(for: app)
                        return

                    default:
                        break
                    }
                } catch {
                    // Ignore transient network errors while polling
                }
            }
        }
    }

    func cancelDownload(for app: ModApp) {
        pollTasks[app.id]?.cancel()
        pollTasks.removeValue(forKey: app.id)
        installStates[app.id] = evaluateAppState(for: app)

        if let cancelURL = URL(string: "\(cleanBaseURL)/cancel/\(app.id)") {
            Task {
                let req = URLRequest(url: cancelURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }

    // MARK: - Launch App Directly by Bundle ID (Zero Breadcrumbs, No URL Scheme Required)
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
            // The user deleted the app from the Home Screen! Reset state back to INSTALL
            UserDefaults.standard.removeObject(forKey: installedKey(for: app.bundleIdentifier))
            installStates[app.id] = .notInstalled
        }
    }

    func installModStoreUpdate() {
        guard let meta = modStoreMeta else { return }
        let encoded = meta.manifestURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? meta.manifestURL
        guard let otaURL = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else { return }
        UIApplication.shared.open(otaURL)
    }

    // MARK: - Local Notifications & Tap Deep-Linking
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