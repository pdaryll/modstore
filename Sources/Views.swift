import SwiftUI
import BackgroundTasks

@main
struct ModStoreApp: App {
    @StateObject private var store = StoreManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: StoreManager.bgTaskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Task { @MainActor in
                StoreManager.shared.scheduleBackgroundRefresh()
                await StoreManager.shared.fetchCatalog(sendNotifications: true)
                refreshTask.setTaskCompleted(success: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(store)
                .onAppear {
                    store.requestPermissions()
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        Task { await store.fetchCatalog(sendNotifications: false) }
                    } else if newPhase == .background {
                        store.scheduleBackgroundRefresh()
                    }
                }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var store: StoreManager

    var body: some View {
        TabView(selection: $store.selectedTab) {
            CatalogListView()
                .tabItem {
                    Label("Apps", systemImage: "square.stack.3d.up.fill")
                }
                .tag(0)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .badge(store.isModStoreUpdateAvailable ? "1" : nil)
                .tag(1)
        }
    }
}

// MARK: - App Catalog List
struct CatalogListView: View {
    @EnvironmentObject var store: StoreManager

    var body: some View {
        NavigationStack(path: $store.navigationPath) {
            List(store.apps) { app in
                NavigationLink(value: app) {
                    HStack(spacing: 14) {
                        AsyncImage(url: URL(string: app.iconURL)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.2))
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name)
                                .font(.headline)
                            Text("v\(app.version) • \(app.formattedSize)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        AppStoreActionButton(
                            state: store.installStates[app.id] ?? .notInstalled,
                            onAction: { store.handlePrimaryAction(for: app) },
                            onCancel: { store.cancelDownload(for: app) }
                        )
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("ModStore")
            .refreshable {
                await store.fetchCatalog(sendNotifications: false)
            }
            .navigationDestination(for: ModApp.self) { app in
                AppDetailView(app: app)
            }
        }
    }
}

// MARK: - App Store Detail Page
struct AppDetailView: View {
    let app: ModApp
    @EnvironmentObject var store: StoreManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 18) {
                    AsyncImage(url: URL(string: app.iconURL)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 22).fill(Color.gray.opacity(0.2))
                    }
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(app.name)
                            .font(.title2.bold())
                        Text(app.bundleIdentifier)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        AppStoreActionButton(
                            state: store.installStates[app.id] ?? .notInstalled,
                            onAction: { store.handlePrimaryAction(for: app) },
                            onCancel: { store.cancelDownload(for: app) }
                        )
                    }
                    Spacer()
                }

                Divider()

                // Metadata Row (Version, Updated Date, Size)
                HStack {
                    metadataColumn(title: "VERSION", value: app.version)
                    Spacer()
                    metadataColumn(title: "UPDATED", value: app.updatedAt)
                    Spacer()
                    metadataColumn(title: "SIZE", value: app.formattedSize)
                }
                .padding(.horizontal, 8)

                Divider()

                // What's New / Changelog
                VStack(alignment: .leading, spacing: 8) {
                    Text("What's New")
                        .font(.title3.bold())
                    Text(app.changelog)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Description
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description")
                        .font(.title3.bold())
                    Text(app.description)
                        .font(.body)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func metadataColumn(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.bold())
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
    }
}

// MARK: - Settings & About Page
struct SettingsView: View {
    @EnvironmentObject var store: StoreManager
    @State private var isCheckingUpdate = false

    var body: some View {
        NavigationStack {
            List {
                Section("Server Configuration") {
                    TextField("https://store.daryll.site", text: $store.serverBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save & Reload Catalog") {
                        Task { await store.fetchCatalog(sendNotifications: false) }
                    }
                }
                
                Section("About ModStore") {
                    HStack {
                        Text("Installed Version")
                        Spacer()
                        Text("v\(store.currentModStoreVersion)")
                            .foregroundColor(.secondary)
                    }
                    if let meta = store.modStoreMeta {
                        HStack {
                            Text("Latest Server Version")
                            Spacer()
                            Text("v\(meta.version)")
                                .foregroundColor(store.isModStoreUpdateAvailable ? .blue : .secondary)
                        }
                        HStack {
                            Text("Last Updated")
                            Spacer()
                            Text(meta.updatedAt)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("ModStore Updates") {
                    Button {
                        Task {
                            isCheckingUpdate = true
                            await store.fetchCatalog(sendNotifications: true)
                            isCheckingUpdate = false
                        }
                    } label: {
                        HStack {
                            Text("Check for Updates")
                            Spacer()
                            if isCheckingUpdate {
                                ProgressView()
                            }
                        }
                    }

                    if store.isModStoreUpdateAvailable, let meta = store.modStoreMeta {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("ModStore v\(meta.version) Available")
                                        .font(.headline)
                                    Text(meta.changelog)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("UPDATE") {
                                    store.installModStoreUpdate()
                                }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(Color.blue)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}