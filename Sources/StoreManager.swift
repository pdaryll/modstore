import SwiftUI
import UserNotifications
import BackgroundTasks

@MainActor
final class StoreManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = StoreManager()
    static let bgTaskID = "com.daryll.modstore.refresh"

    // Change this to your server's catalog URL
    @Published var serverBaseURL: String = UserDefaults.standard.string(forKey: "serverBaseURL") ?? "https://store.daryll.site" {
        didSet {
        UserDefaults.standard.set(serverBaseURL, forKey: "serverBaseURL")
        }
    }

    var catalogURL: URL {
        let cleanBase = serverBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(cleanBase)/catalog.json") ?? URL(string: "https://localhost/catalog.json")!
    }

    @Published var apps: [ModApp] = []
    @Published var modStoreMeta: ModStoreMeta?
    @Published var installStates: [String: InstallState] = [:]
    @Published var modStoreInstallState: InstallState = .installed

    // Navigation & Deep-Linking State
    @Published var selectedTab: Int = 0 // 0 = Apps, 1 = Settings
    @Published var navigationPath: [ModApp] = []
    private var pendingDeepLinkAppID: String?

    private var downloadTimers: [String: Timer] = [:]

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

    // MARK: - Fetch Catalog & Check for Updates
    func fetchCatalog(sendNotifications: Bool = false) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: catalogURL)
            let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
            self.apps = decoded.apps
            self.modStoreMeta = decoded.modStore
            refreshInstallStates(sendNotifications: sendNotifications)

            // Resolve pending notification deep link if opened from cold start
            if let pendingID = pendingDeepLinkAppID,
               let targetApp = apps.first(where: { $0.id == pendingID }) {
                pendingDeepLinkAppID = nil
                selectedTab = 0
                navigationPath = [targetApp]
            }
        } catch {
            print("Failed to fetch catalog: \(error)")
        }
    }

    func refreshInstallStates(sendNotifications: Bool = false) {
        // 1. Check each catalog app
        for app in apps {
            if case .downloading = installStates[app.id] { continue }
            if case .awaitingConfirmation = installStates[app.id] { continue }

            let state = evaluateAppState(for: app)
            installStates[app.id] = state

            if sendNotifications && state == .updateAvailable {
                sendUpdateNotification(
                    id: "update-\(app.id)-\(app.version)",
                    title: "Update Available",
                    body: "\(app.name) v\(app.version) is ready to install.",
                    userInfo: ["target": "app_detail", "appID": app.id]
                )
            }
        }

        // 2. Check if ModStore itself has an update
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
        let baseScheme = URL(string: "myrepo-app-\(app.bundleIdentifier)://")!
        let versionScheme = URL(string: "myrepo-ver-\(app.bundleIdentifier)-\(app.version)://")!

        let canOpenBase = UIApplication.shared.canOpenURL(baseScheme)
        let canOpenVer = UIApplication.shared.canOpenURL(versionScheme)
        let savedVersion = UserDefaults.standard.string(forKey: "installed_\(app.id)")

        if canOpenVer || savedVersion == app.version {
            return .installed
        } else if canOpenBase || savedVersion != nil {
            return .updateAvailable
        } else {
            return .notInstalled
        }
    }

    // MARK: - Install / Cancel / Open Actions
    func handlePrimaryAction(for app: ModApp) {
        let state = installStates[app.id] ?? .notInstalled
        switch state {
        case .installed:
            openApp(app)
        case .notInstalled, .updateAvailable:
            startOTAInstall(for: app)
        default:
            break
        }
    }

    func startOTAInstall(for app: ModApp) {
        installStates[app.id] = .awaitingConfirmation
        let encodedManifest = app.manifestURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? app.manifestURL
        guard let otaURL = URL(string: "itms-services://?action=download-manifest&url=\(encodedManifest)") else {
            installStates[app.id] = evaluateAppState(for: app)
            return
        }

        UIApplication.shared.open(otaURL) { [weak self] success in
            guard let self = self, success else { return }
            // Transition from spinner to circular progress ring once prompt is confirmed
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.beginProgressTracking(for: app)
            }
        }
    }

    private func beginProgressTracking(for app: ModApp) {
        var progress = 0.05
        installStates[app.id] = .downloading(progress: progress)

        downloadTimers[app.id]?.invalidate()
        downloadTimers[app.id] = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else { return }
                progress += 0.08
                if progress >= 1.0 {
                    timer.invalidate()
                    self.downloadTimers.removeValue(forKey: app.id)
                    UserDefaults.standard.set(app.version, forKey: "installed_\(app.id)")
                    self.installStates[app.id] = .installed
                } else {
                    self.installStates[app.id] = .downloading(progress: progress)
                }
            }
        }
    }

    func cancelDownload(for app: ModApp) {
        downloadTimers[app.id]?.invalidate()
        downloadTimers.removeValue(forKey: app.id)
        // Notify server to drop stream if using session ID tracking
        installStates[app.id] = evaluateAppState(for: app)
    }

    func openApp(_ app: ModApp) {
        guard let url = URL(string: "myrepo-app-\(app.bundleIdentifier)://") else { return }
        UIApplication.shared.open(url)
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
                // Open Settings / About tab directly
                self.selectedTab = 1
            } else if target == "app_detail", let appID = appID {
                // Open the Apps tab and push the specific App Detail Page
                self.selectedTab = 0
                if let matchingApp = self.apps.first(where: { $0.id == appID }) {
                    self.navigationPath = [matchingApp]
                } else {
                    self.pendingDeepLinkAppID = appID
                }
            }
        }
        completionHandler()
    }

    // MARK: - Background App Refresh
    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60) // Check every ~30 mins
        try? BGTaskScheduler.shared.submit(request)
    }
}