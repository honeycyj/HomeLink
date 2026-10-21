import SwiftUI

/// Keep secondary actions native and neutral; each page opts its primary action
/// into borderedProminent explicitly. System controls retain focus and key handling.
struct SecondaryActionButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.bordered)
            .tint(nil)
            .buttonBorderShape(.roundedRectangle)
            .font(.system(size: 13))
            .controlSize(.regular)
    }
}

/// Settings category artwork uses SF Symbols; status is shown separately.
struct SettingsIcon: View {
    let symbol: String
    var color: Color = .blue

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsEntryLabel: View {
    let title: String
    let symbol: String
    var color: Color = .blue
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }
}

struct SettingsHeading: View {
    let title: String
    let back: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).foregroundStyle(.primary).help("返回设置").accessibilityLabel("返回设置")
            Text(title).font(.title2.weight(.semibold))
            Spacer()
        }
    }
}

struct SettingsStatus: View {
    let text: String
    var symbol = "info.circle"
    var color: Color = .secondary
    var body: some View {
        Label(text, systemImage: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
