import AppKit

/// Normal app/menu/system termination waits for the active attempt and tunnel to finish cleanup.
@MainActor
final class HomeLinkAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: DeviceStore?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await store?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
