import AppKit

/// Exercise the real native button action on a private, never-shown window.
@main
struct SettingsWindowControlsTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { fatalError("No display available") }
        let visible = screen.visibleFrame
        let window = NSWindow(contentRect: NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 520, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 520)
        window.contentMaxSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        let accessor = SettingsWindowControls.WindowAccessor(frame: .zero)
        window.contentView!.addSubview(accessor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let zoom = window.standardWindowButton(.zoomButton)!
        precondition(zoom.target === accessor && zoom.isEnabled)
        precondition(zoom.action != #selector(NSWindow.performZoom(_:)), "Recursive button action")
        precondition(window.titlebarAppearsTransparent)
        let original = window.frame
        for _ in 0..<3 {
            zoom.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            precondition(abs(window.frame.width - original.width) < 1, "Zoom changed width")
            precondition(abs(window.frame.height - visible.height) < 1, "Zoom did not fill usable height")
            precondition(abs(window.frame.minY - visible.minY) < 1, "Zoom overlaps menu bar or Dock")
            precondition(!window.styleMask.contains(.fullScreen))
            zoom.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            precondition(abs(window.frame.width - original.width) < 1)
            precondition(abs(window.frame.height - original.height) < 1, "Zoom did not restore height")
            precondition(abs(window.frame.minY - original.minY) < 1, "Zoom did not restore position")
        }
        window.close()
        print("PASS: native button action, three vertical zoom/restore cycles, width and screen bounds, transparent title bar")
    }
}
