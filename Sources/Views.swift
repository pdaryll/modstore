import SwiftUI
import UIKit
import BackgroundTasks

// MARK: - Smart Single-Line Text (Only Fades When String Actually Overflows Available Width)
struct SmartFadeText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    var alignment: Alignment = .leading

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // 1. If the string fits within the available width, render sharply with NO fade mask
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: alignment)

            // 2. Only if the string is unusually long and overflows, apply a subtle right-edge fade
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: alignment)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.90),
                            .init(color: .black.opacity(0.08), location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }
}

// MARK: - Instant In-Memory Icon Cache
final class IconMemoryCache {
    static let shared = IconMemoryCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for urlString: String) -> UIImage? {
        cache.object(forKey: urlString as NSString)
    }

    func insert(_ image: UIImage, for urlString: String) {
        cache.setObject(image, forKey: urlString as NSString)
    }
}

struct CachedAppIcon: View {
    let urlString: String
    let size: CGFloat
    let cornerRadius: CGFloat

    @State private var loadedImage: UIImage?

    var body: some View {
        Group {
            if let img = loadedImage ?? IconMemoryCache.shared.image(for: urlString) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.2))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: urlString) {
            if let cached = IconMemoryCache.shared.image(for: urlString) {
                loadedImage = cached
                return
            }
            guard let url = URL(string: urlString), !urlString.isEmpty else { return }
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let uiImg = UIImage(data: data) {
                IconMemoryCache.shared.insert(uiImg, for: urlString)
                loadedImage = uiImg
            }
        }
    }
}

@main
struct ModStoreApp: App {
    @StateObject private var store = StoreManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasCompletedInitialLoad = false

    init() {
        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()

        UINavigationBar.appearance().standardAppearance = standard
        UINavigationBar.appearance().compactAppearance = standard
        UINavigationBar.appearance().scrollEdgeAppearance = scrollEdge
        UINavigationBar.appearance().prefersLargeTitles = true

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
                .task {
                    store.requestPermissions()
                    await store.fetchCatalog(sendNotifications: false)
                    hasCompletedInitialLoad = true
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active && hasCompletedInitialLoad {
                        // Immediately re-check if any app was deleted on the Home Screen
                        store.refreshInstallStates(sendNotifications: false)
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
        ZStack(alignment: .top) {
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

            // Floating Toast Banner when an install fails or status updates
            if let banner = store.statusBanner {
                HStack(spacing: 10) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundColor(banner.isError ? .yellow : .blue)
                    Text(banner.message)
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(999)
            }
        }
    }
}

// MARK: - App Catalog List
struct CatalogListView: View {
    @EnvironmentObject var store: StoreManager
    @State private var navigationPath: [ModApp] = []

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List(store.apps) { app in
                let currentState = store.installStates[app.id] ?? .notInstalled
                let isAppInstalled = (currentState == .installed || currentState == .updateAvailable)

                ZStack {
                    NavigationLink(value: app) {
                        EmptyView()
                    }
                    .opacity(0)

                    HStack(spacing: 14) {
                        CachedAppIcon(urlString: app.iconURL, size: 60, cornerRadius: 14)

                        VStack(alignment: .leading, spacing: 4) {
                            SmartFadeText(
                                text: app.name,
                                font: .headline,
                                color: .primary,
                                alignment: .leading
                            )

                            SmartFadeText(
                                text: "v\(app.version) • \(app.formattedSize) • \(app.description)",
                                font: .caption,
                                color: .secondary,
                                alignment: .leading
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        AppStoreActionButton(
                            state: currentState,
                            alignment: .center,
                            onAction: { store.handlePrimaryAction(for: app) },
                            onCancel: { store.cancelDownload(for: app) }
                        )
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .contextMenu {
                    if isAppInstalled {
                        Button {
                            store.openAppByBundleID(app)
                        } label: {
                            Label("Open", systemImage: "arrow.up.forward.app")
                        }

                        Button {
                            store.reinstallApp(app)
                        } label: {
                            Label("Re-install", systemImage: "arrow.clockwise")
                        }
                    } else {
                        Button {
                            store.startOTAInstall(for: app)
                        } label: {
                            Label("Install", systemImage: "arrow.down.circle")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("ModStore")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                store.refreshInstallStates(sendNotifications: false)
            }
            .refreshable {
                await store.fetchCatalog(sendNotifications: false)
            }
            .navigationDestination(for: ModApp.self) { app in
                AppDetailView(app: app)
            }
            .onChange(of: store.deepLinkApp) { targetApp in
                if let targetApp = targetApp {
                    navigationPath = [targetApp]
                    store.deepLinkApp = nil
                }
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
                HStack(spacing: 18) {
                    CachedAppIcon(urlString: app.iconURL, size: 96, cornerRadius: 22)

                    VStack(alignment: .leading, spacing: 6) {
                        SmartFadeText(
                            text: app.name,
                            font: .title2.bold(),
                            color: .primary,
                            alignment: .leading
                        )

                        SmartFadeText(
                            text: app.bundleIdentifier,
                            font: .caption,
                            color: .secondary,
                            alignment: .leading
                        )
                        .padding(.bottom, 2)

                        AppStoreActionButton(
                            state: store.installStates[app.id] ?? .notInstalled,
                            alignment: .leading,
                            onAction: { store.handlePrimaryAction(for: app) },
                            onCancel: { store.cancelDownload(for: app) }
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                // Uniform 3-Column Metadata Bar (Only fades if a value overflows its column)
                HStack(spacing: 0) {
                    metadataColumn(title: "VERSION", value: "v\(app.version)")
                    Divider().frame(height: 32)
                    metadataColumn(title: "UPDATED", value: app.updatedAt)
                    Divider().frame(height: 32)
                    metadataColumn(title: "SIZE", value: app.formattedSize)
                }
                .padding(.vertical, 2)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("What's New")
                            .font(.title3.bold())
                        Spacer()
                        Text("Version \(app.version)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Text(app.changelog)
                        .font(.subheadline)
                        .foregroundColor(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Description")
                        .font(.title3.bold())
                    Text(app.description)
                        .font(.body)
                        .foregroundColor(.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.refreshInstallStates(sendNotifications: false)
        }
    }

    private func metadataColumn(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.bold())
                .foregroundColor(.secondary)
                .lineLimit(1)

            SmartFadeText(
                text: value,
                font: .subheadline.weight(.semibold),
                color: .primary,
                alignment: .center
            )
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity)
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
                                .frame(width: 82, height: 30)
                                .background(Color.blue)
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}