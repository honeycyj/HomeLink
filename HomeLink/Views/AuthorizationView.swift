import SwiftUI

struct AuthorizationView: View {
    @Bindable var store: DeviceStore
    let device: RemoteDevice
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var switchConfirmation = false
    @State private var showingPublicKey = false

    private var connectingThisDevice: Bool {
        if case .connecting(let current) = store.connection.state { return current.id == device.id }
        return false
    }

    private var cancellingThisDevice: Bool {
        if case .disconnecting(let current) = store.connection.state { return current?.id == device.id }
        return false
    }

    private var secondaryTitle: String {
        if cancellingThisDevice { return "正在取消" }
        return connectingThisDevice ? "取消连接" : "稍后设置"
    }

    private var connectTitle: String {
        if cancellingThisDevice { return "正在取消" }
        return connectingThisDevice ? "正在连接" : "已授权，连接"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("让 \(device.name) 允许连接").font(.system(size: 18, weight: .semibold))
                Text("在这台远程 Mac 完成一次授权，以后直接连接。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("1. 在远程 Mac 开启共享").fontWeight(.medium)
                Text("系统设置 → 通用 → 共享，开启「远程登录」与「屏幕共享」，仅允许你的账户访问。")
                    .foregroundStyle(.secondary)
                Text("2. 复制并执行授权命令").fontWeight(.medium).padding(.top, 4)
                Text("以 \(device.username) 用户登录这台远程 Mac，在终端粘贴并执行下面的命令。已经授权过可直接连接。")
                    .foregroundStyle(.secondary)

            }
            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            AuthorizationCommandCard(publicKey: device.publicKey, explanation: nil, prominent: true)
            DisclosureGroup("单独查看或复制公钥", isExpanded: $showingPublicKey) {
                PublicKeyCard(publicKey: device.publicKey, title: "本机公钥")
                    .padding(.top, 6)
            }
            .font(.system(size: 12))
            Text("命令可重复执行并保留已有公钥。网络入口仍需提前配置，不要将屏幕共享的 5900 端口直接暴露到公网。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Button("查看连接日志") { store.openConnectionLog() }
            }
            Divider()
            HStack {
                Button(secondaryTitle) {
                    if connectingThisDevice { store.disconnect() }
                    else { dismissWindow(id: "add-device") }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(cancellingThisDevice)
                Spacer()
                if connectingThisDevice || cancellingThisDevice { ProgressView().controlSize(.small) }
                Button(connectTitle) {
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
