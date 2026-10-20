import SwiftUI

@main
struct HomeLinkApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(HomeLinkAppDelegate.self) private var appDelegate
    @State private var store: DeviceStore

    init() {
        SingleInstance.acquire()
        #if DEBUG
        let fixtureDirectory = CommandLine.arguments.contains("--empty-ui-fixture")
            ? URL.applicationSupportDirectory.appendingPathComponent("HomeLink/UITests/\(UUID().uuidString)") : nil
        #else
        let fixtureDirectory: URL? = nil
        #endif
        let store = DeviceStore(directory: fixtureDirectory, cleanupTemporaryKeys: true)
        _store = State(initialValue: store)
        appDelegate.store = store
        #if DEBUG
        // Exercise the real sandboxed app and its saved Keychain identity from the run script.
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
            GlassEffectContainer(spacing: 12) {
                DeviceMenuView(store: store)
            }
        }
        .menuBarExtraStyle(.window)
        .onChange(of: store.isLoading, initial: true) { _, loading in
            if !loading && store.devices.isEmpty && store.repository.loadError == nil { openWindow(id: "add-device") }
        }

        Window("添加 Mac", id: "add-device") {
            SetupView(store: store)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            PreferencesView(store: store)
        }
        .windowResizability(.contentSize)
    }
}
