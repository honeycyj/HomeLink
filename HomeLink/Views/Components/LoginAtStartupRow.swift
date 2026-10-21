import SwiftUI
import ServiceManagement

struct LoginAtStartupRow: View {
    @Bindable var store: DeviceStore

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: "power", color: .gray)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("登录时启动 HomeLink").fontWeight(.medium)
                    Spacer(minLength: 12)
                    Toggle("登录时启动 HomeLink", isOn: Binding(get: { store.launchAtLogin }, set: store.setLaunchAtLogin))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Text(store.launchAtLoginDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                if let error = store.launchAtLoginError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                }
                if store.launchAtLoginNeedsApproval {
                    Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
        .onAppear { store.refreshLaunchAtLogin() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshLaunchAtLogin()
        }
    }
}
