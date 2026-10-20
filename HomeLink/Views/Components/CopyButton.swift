import SwiftUI

/// Shared feedback resets when the selected public content changes.
struct CopyButton: View {
    let value: String
    let title: String
    let copiedTitle: String
    @State private var copied = false

    var body: some View {
        Button(copied ? copiedTitle : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
        }
        .onChange(of: value) { _, _ in copied = false }
    }
}
