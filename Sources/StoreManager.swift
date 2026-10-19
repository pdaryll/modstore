import SwiftUI
import UserNotifications
import BackgroundTasks

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
    @Published var navigationPath: [ModApp] = []
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

    func fetchCatalog(sendNotifications: Bool = false) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: catalogURL)
            let decoded = try JSONDecoder().decode(CatalogResponse.self, from: data)
            self.apps = decoded.apps
            self.modStoreMeta = decoded.modStore
            refreshInstallStates(sendNotifications: sendNotifications)

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
        let savedVersion = UserDefaults.standard.string(forKey: "installed_\(app.id)")

        // Check if the untouched app's native URL scheme (e.g. twitter://) responds on device
        if !app.urlScheme.isEmpty,
           let schemeURL = URL(string: "\(app.urlScheme)://") {
            let isPresentOnDevice = UIApplication.shared.canOpenURL(schemeURL)
            if !isPresentOnDevice {
                // App is not installed (or was deleted from the Home Screen)
                UserDefaults.standard.removeObject(forKey: "installed_\(app.id)")
                return .notInstalled
            }
            if let saved = savedVersion, saved != app.version {
                return .updateAvailable
            }
            return .installed
        }

        // Fallback if IPA has no URL scheme in its Info.plist
        if let saved = savedVersion {
            return saved == app.version ? .installed : .updateAvailable
        }
        return .notInstalled
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
        // 1. Show spinning circle while waiting for the iOS "Install / Cancel" popup
        installStates[app.id] = .awaitingConfirmation

        let encodedManifest = app.manifestURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? app.manifestURL
        guard let otaURL = URL(string: "itms-services://?action=download-manifest&url=\(encodedManifest)") else {
            installStates[app.id] = evaluateAppState(for: app)
            return
        }

        UIApplication.shared.open(otaURL) { [weak self] success in
            guard let self = self else { return }
            if !success {
                self.installStates[app.id] = self.evaluateAppState(for: app)
                return
            }
            self.startPollingServerProgress(for: app)
        }
    }

    private func startPollingServerProgress(for app: ModApp) {
        pollTasks[app.id]?.cancel()

        pollTasks[app.id] = Task { @MainActor in
            guard let progressURL = URL(string: "\(cleanBaseURL)/progress/\(app.id)") else { return }
            var waitingTicks = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000) // Poll every 0.35s
                guard !Task.isCancelled else { break }

                do {
                    let (data, _) = try await URLSession.shared.data(from: progressURL)
                    let resp = try JSONDecoder().decode(ProgressResponse.self, from: data)

                    switch resp.status {
                    case "waiting", "idle":
                        // Still on the iOS system popup; keep spinning circle
                        waitingTicks += 1
                        installStates[app.id] = .awaitingConfirmation
                        // If user tapped "Cancel" on the iOS popup, the app returns to .active and download never starts
                        if waitingTicks > 8 && UIApplication.shared.applicationState == .active {
                            installStates[app.id] = evaluateAppState(for: app)
                            return
                        }

                    case "downloading":
                        // User tapped "Install" on the iOS popup; show circular progress ring with stop square
                        waitingTicks = 0
                        installStates[app.id] = .downloading(progress: max(0.05, resp.progress))

                    case "completed":
                        installStates[app.id] = .downloading(progress: 1.0)
                        // Wait ~3s for iOS installd to finish unpacking and verifying the signed IPA
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        UserDefaults.standard.set(app.version, forKey: "installed_\(app.id)")
                        installStates[app.id] = .installed
                        return

                    case "cancelled":
                        installStates[app.id] = evaluateAppState(for: app)
                        return

                    default:
                        break
                    }
                } catch {
                    // Ignore transient network hiccups while polling
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
                _ = try? await URLSession.shared.data(from: cancelURL)
            }
        }
    }

    func openApp(_ app: ModApp) {
        guard !app.urlScheme.isEmpty,
              let url = URL(string: "\(app.urlScheme)://") else { return }
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
                self.selectedTab = 1
            } else if target == "app_detail", let appID = appID {
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

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}