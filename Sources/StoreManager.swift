import SwiftUI
import UIKit
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
    private var previousStates: [String: InstallState] = [:]

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

    private func revertState(for app: ModApp) {
        installStates[app.id] = previousStates[app.id] ?? evaluateAppState(for: app)
    }

    // MARK: - Install / Cancel / Reinstall / Delete Actions
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

    func deleteInstalledApp(_ app: ModApp) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        pollTasks[app.id]?.cancel()
        pollTasks.removeValue(forKey: app.id)

        // Attempt system workspace uninstall if permitted, and clear ModStore's installed record
        if let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
           let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject {
            let selector = NSSelectorFromString("uninstallApplication:withOptions:")
            if workspace.responds(to: selector) {
                typealias UninstallFunc = @convention(c) (AnyObject, Selector, NSString, AnyObject?) -> Bool
                let imp = workspace.method(for: selector)
                let uninstall = unsafeBitCast(imp, to: UninstallFunc.self)
                _ = uninstall(workspace, selector, app.bundleIdentifier as NSString, nil)
            }
        }

        UserDefaults.standard.removeObject(forKey: installedKey(for: app.bundleIdentifier))
        previousStates.removeValue(forKey: app.id)
        installStates[app.id] = .notInstalled
    }

    func startOTAInstall(for app: ModApp) {
        // Remember what state the button was in so we can revert cleanly on Cancel or Error
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

            let encodedManifest = app.manifestURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? app.manifestURL
            guard let otaURL = URL(string: "itms-services://?action=download-manifest&url=\(encodedManifest)") else {
                revertState(for: app)
                return
            }

            let opened = await UIApplication.shared.open(otaURL)
            if !opened {
                revertState(for: app)
                return
            }

            startPollingServerProgress(for: app)
        }
    }

    private func startPollingServerProgress(for app: ModApp) {
        pollTasks[app.id]?.cancel()

        pollTasks[app.id] = Task { @MainActor in
            guard let progressURL = URL(string: "\(cleanBaseURL)/progress/\(app.id)") else {
                revertState(for: app)
                return
            }

            var sawSystemAlert = false
            var postAlertActiveTicks = 0
            var initialNoAlertTicks = 0
            var consecutiveErrors = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000) // Poll every 0.3s
                guard !Task.isCancelled else { break }

                if UIApplication.shared.applicationState != .active {
                    sawSystemAlert = true
                }

                do {
                    let req = URLRequest(url: progressURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 4)
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let resp = try JSONDecoder().decode(ProgressResponse.self, from: data)
                    consecutiveErrors = 0

                    switch resp.status {
                    case "waiting", "idle":
                        installStates[app.id] = .awaitingConfirmation

                        if sawSystemAlert {
                            // Once user taps Cancel or Install, the popup closes and app becomes .active
                            if UIApplication.shared.applicationState == .active {
                                postAlertActiveTicks += 1
                                // If 4 ticks (1.2s) pass after popup closes and download hasn't started, user tapped Cancel!
                                if postAlertActiveTicks >= 4 {
                                    revertState(for: app)
                                    return
                                }
                            }
                        } else {
                            // If system alert never appeared after ~3 seconds, manifest failed -> revert
                            initialNoAlertTicks += 1
                            if initialNoAlertTicks >= 10 {
                                revertState(for: app)
                                return
                            }
                        }

                    case "downloading":
                        postAlertActiveTicks = 0
                        installStates[app.id] = .downloading(progress: max(0.05, resp.progress))

                    case "completed":
                        installStates[app.id] = .downloading(progress: 1.0)
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        UserDefaults.standard.set(app.version, forKey: installedKey(for: app.bundleIdentifier))
                        previousStates[app.id] = .installed
                        installStates[app.id] = .installed
                        return

                    case "cancelled", "error":
                        revertState(for: app)
                        return

                    default:
                        break
                    }
                } catch {
                    consecutiveErrors += 1
                    if consecutiveErrors >= 3 {
                        revertState(for: app)
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