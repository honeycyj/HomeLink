import AppKit

/// AppKit owns standard menus, dialogs and file authorization; SwiftUI owns feature state.
@MainActor
enum SystemDialogs {
    private static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = NSApp.keyWindow, window.attachedSheet == nil, window.sheetParent == nil {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        }
        return alert.runModal()
    }

    static func confirm(title: String, message: String, action: String, destructive: Bool = false) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = destructive
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        let response = await present(alert)
        return !Task.isCancelled && response == .alertFirstButtonReturn
    }

    static func rename(_ value: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = "重命名设备"
        alert.informativeText = "仅修改列表中的显示名称。"
        let input = NSTextField(string: value)
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        input.setAccessibilityLabel("设备名称")
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = input
        guard await present(alert) == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }

    static func showPublicKey(_ device: AuthorizedDevice) async {
        let alert = NSAlert()
        alert.messageText = device.name + " 的公钥"
        alert.informativeText = device.key.fingerprint
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 90))
        let text = NSTextView(frame: scroll.bounds)
        text.string = device.key.text; text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "复制公钥"); alert.addButton(withTitle: "完成")
        if await present(alert) == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(device.key.text, forType: .string)
        }
    }

    static func confirmLocalKeyManagement() async -> Bool {
        await confirm(title: "允许管理连接公钥？",
                      message: "HomeLink 将读取和维护当前账户的连接公钥，保留已有授权。",
                      action: "允许")
    }

    static func openSharing() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!)
    }
}
