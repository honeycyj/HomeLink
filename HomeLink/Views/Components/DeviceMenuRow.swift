import SwiftUI

struct DeviceMenuRow<Actions: View>: View {
    let device: RemoteDevice
    let isActive: Bool
    let isConnecting: Bool
    let action: () -> Void
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false
    @State private var hoveringActions = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 16, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(isConnected ? Color.white : iconColor)
                        .frame(width: 32, height: 32)
                        .background(isConnected ? Color.accentColor : iconBackground, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(device.name.prefix(30)))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(hovering ? Color.white : Color.primary)
                            .lineLimit(1)
                        Text(status).font(.system(size: 11))
                            .foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(device.name)，\(status)")
            if isConnecting {
                ProgressView().controlSize(.mini).tint(hovering ? .white : .secondary)
            }
            Menu(content: actions) {
                Image(systemName: "ellipsis").font(.system(size: 15))
                    .foregroundStyle(hovering ? Color.white : Color.secondary.opacity(hoveringActions ? 1 : 0.7))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(hovering ? .white : .secondary)
            .fixedSize()
            .onHover { hoveringActions = $0 }
            .help("\(device.name) 的操作")
            .accessibilityLabel("\(device.name) 的更多操作")
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(hovering ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }

    private var isConnected: Bool { isActive && !isConnecting }
    private var iconColor: Color { hovering ? .white.opacity(0.8) : .secondary }
    private var iconBackground: Color { hovering ? .white.opacity(0.16) : .primary.opacity(0.12) }

    private var status: String {
        if isConnecting { return "正在连接" }
        if isActive { return "已连接 · 点击打开桌面" }
        if !device.hasConnected { return "待授权 · 点击继续设置" }
        return "未连接 · 点击连接"
    }
}
