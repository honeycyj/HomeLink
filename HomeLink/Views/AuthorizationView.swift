import SwiftUI

struct AuthorizationView: View {
    @Bindable var store: DeviceStore
    let device: RemoteDevice
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var switchConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("让 Studio 允许连接").font(.system(size: 18, weight: .semibold))
                Text("复制公钥，在 Studio 完成一次设置，以后直接连接。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            PublicKeyCard(publicKey: device.publicKey, title: "这台笔记本的公钥")
            VStack(alignment: .leading, spacing: 8) {
                Text("1. 在 Studio 开启共享").fontWeight(.medium)
                Text("系统设置 → 通用 → 共享，开启「远程登录」与「屏幕共享」，仅允许你的账户访问。")
                    .foregroundStyle(.secondary)
                Text("2. 在 Studio 粘贴公钥").fontWeight(.medium).padding(.top, 4)
                Text("以 \(device.username) 用户登录 Studio，在终端执行一次授权命令。已经授权过可直接连接。")
                    .foregroundStyle(.secondary)

            }
            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("安全建议").fontWeight(.medium)
                Text("仅允许指定账户访问。确认密钥可以登录后，建议关闭 SSH 密码登录、交互式认证与 root 登录。授权命令已附上配置说明，不会自动修改现有 SSH 设置。")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            AuthorizationCommandCard(publicKey: device.publicKey, explanation: nil)
            Text("命令可重复执行并保留已有公钥。网络入口仍需提前配置，不要将屏幕共享的 5900 端口直接暴露到公网。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Button("查看连接日志") { store.openConnectionLog() }
            }
            Divider()
            HStack {
                Button("稍后设置") { dismissWindow(id: "add-device") }.keyboardShortcut(.cancelAction)
                Spacer()
                if store.isConnecting { ProgressView().controlSize(.small) }
                Button(store.isConnecting ? "正在连接" : "已授权，连接") {
                    if store.activeID != nil && store.activeID != device.id { switchConfirmation = true }
                    else { connect() }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(store.isConnecting)
            }
        }
        .padding(24).frame(width: 520)
        .alert("断开当前设备并连接\(device.name)？", isPresented: $switchConfirmation) {
            Button("取消", role: .cancel) {}
            Button("断开并连接", action: connect)
        } message: { Text("当前设备的屏幕共享也会中断，设备资料会保留。") }
    }

    private func connect() {
        Task {
            await store.connect(device)
            if store.activeID == device.id && store.localPort != nil { dismissWindow(id: "add-device") }
        }
    }
}
