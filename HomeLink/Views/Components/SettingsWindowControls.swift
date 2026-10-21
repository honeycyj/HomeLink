import SwiftUI

/// A narrow bridge for a transparent native title bar and vertical-only zoom.
struct SettingsWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowAccessor { WindowAccessor() }
    func updateNSView(_ view: WindowAccessor, context: Context) {}

    final class WindowAccessor: NSView {
        private var restoreFrame: NSRect?
        private var zoomFrame: NSRect?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window,
                      let zoom = window.standardWindowButton(.zoomButton) else { return }
                window.titlebarAppearsTransparent = true
                window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary, .fullScreenAllowsTiling])
                window.collectionBehavior.insert([.fullScreenNone, .fullScreenDisallowsTiling])
                zoom.target = self
                // Never target performZoom: it clicks this button again.
                zoom.action = #selector(self.zoomVertically(_:))
                zoom.isEnabled = true
                zoom.toolTip = "放大或还原窗口"
            }
        }

        @objc private func zoomVertically(_ sender: Any?) {
            guard let window, let screen = window.screen else { return }
            let visible = screen.visibleFrame
            let current = window.frame
            if let saved = restoreFrame, let previous = zoomFrame,
               abs(current.width - previous.width) < 1,
               abs(current.height - previous.height) < 1 {
                // Fit a saved frame to the current display if displays changed.
                var restored = saved
                restored.size.width = min(saved.width, visible.width)
                restored.size.height = min(saved.height, visible.height)
                restored.origin.x = min(max(restored.minX, visible.minX), visible.maxX - restored.width)
                restored.origin.y = min(max(restored.minY, visible.minY), visible.maxY - restored.height)
                restoreFrame = nil
                zoomFrame = nil
                window.setFrame(restored, display: true, animate: true)
            } else {
                restoreFrame = current
                let width = min(current.width, visible.width)
                let expanded = NSRect(
                    x: min(max(current.minX, visible.minX), visible.maxX - width),
                    y: visible.minY, width: width, height: visible.height)
                zoomFrame = expanded
                window.setFrame(expanded, display: true, animate: true)
            }
        }
    }
}
