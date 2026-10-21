import SwiftUI

@main
struct HomeLinkApp: App {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @NSApplicationDelegateAdaptor(HomeLinkAppDelegate.self) private var appDelegate
    @State private var store: DeviceStore
    @State private var local: LocalAccessStore
    @State private var ddns: DDNSStore

    init() {
        SingleInstance.acquire()
        HomeLinkStorage.importLegacyPreferences()
        #if DEBUG
        let fixtureDirectory = CommandLine.arguments.contains("--empty-ui-fixture") || CommandLine.arguments.contains("--studio-ui-fixture")
            ? URL.applicationSupportDirectory.appendingPathComponent("HomeLink/UITests/\(UUID().uuidString)") : nil
        #else
        let fixtureDirectory: URL? = nil
        #endif
        let store = DeviceStore(directory: fixtureDirectory, cleanupTemporaryKeys: true)
        _store = State(initialValue: store)
        let defaults = fixtureDirectory.flatMap { UserDefaults(suiteName: "local.homelink.preview.\($0.lastPathComponent)") } ?? .standard
        let local = LocalAccessStore(defaults: defaults)
        let ddns = DDNSStore(directory: fixtureDirectory)
        _local = State(initialValue: local)
        _ddns = State(initialValue: ddns)
        appDelegate.store = store
        appDelegate.ddns = ddns
        #if DEBUG
        // Exercise the signed app and its saved Keychain identity from the run script.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--connect-saved-device"),
           arguments.indices.contains(flag + 1),
           let id = UUID(uuidString: arguments[flag + 1]) {
            Task {
                await store.prepare()
                if let device = store.device(id) { await store.connect(device) }
            }
        }
        #endif
    }

    var body: some Scene {
        MenuBarExtra("HomeLink", systemImage: "link") {
            DeviceMenuView(store: store)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: store.isLoading, initial: true) { _, loading in
            #if DEBUG
            if !loading && (CommandLine.arguments.contains("--studio-ui-fixture") || CommandLine.arguments.contains("--show-settings") || CommandLine.arguments.contains("--show-local-access")) {
                if CommandLine.arguments.contains("--studio-ui-fixture") { local.installPreviewDevices() }
                store.preferencesPage = CommandLine.arguments.contains("--studio-ui-fixture") || CommandLine.arguments.contains("--show-local-access") ? .localAccess : .overview
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
                return
            }
            #endif
            if !loading && store.devices.isEmpty && store.repository.loadError == nil { openWindow(id: "add-device") }
        }

        Window("添加 Mac", id: "add-device") {
            SetupView(store: store)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsRootView(store: store, local: local, ddns: ddns)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 600)
        .windowIdealSize(.maximum)
    }
}
