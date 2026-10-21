import SwiftUI

struct LocalAccessView: View {
    @Bindable var store: LocalAccessStore
    let back: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var operationError: String?
    @State private var authorizing = false
    @State private var refreshRequest = 0
    @State private var forceRefresh = false
    @State private var awaitingSharingReturn = false
    @State private var visible = false
    @State private var pendingRefresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeading(title: "本机访问", back: back)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("当前账户：\(NSUserName()) · 仅管理这个账户的授权公钥")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    SettingsCard {
                        serviceRow("远程登录", symbol: "terminal", status: store.sharing.ssh)
                        Divider()
                        serviceRow("屏幕共享", symbol: "display", status: store.sharing.screenSharing)
                        Divider()
                        HStack(spacing: 12) {
                            SettingsIcon(symbol: "key.fill", color: .gray)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("设备授权管理").fontWeight(.medium)
                                Text(store.needsAuthorization ? "允许读取和维护本机连接公钥，保留已有授权。" : (store.error != nil ? "暂时无法读取连接公钥，请查看下方提示。" : "已允许管理本机连接公钥，可查看和添加设备。"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if store.needsAuthorization {
                                Button("授权", action: authorize)
                                    .disabled(authorizing || store.busy)
                            } else {
                                Label(store.error == nil ? "已允许" : "需要处理", systemImage: store.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle")
                                    .font(.system(size: 11)).foregroundStyle(store.error == nil ? Color.green : .orange).fixedSize()
                            }
                            if authorizing { ProgressView().controlSize(.mini) }
                        }
                    }
                    HStack {
                        Text("已授权设备").fontWeight(.semibold)
                        Spacer()
                        if store.busy { ProgressView().controlSize(.mini) }
                        if !store.devices.isEmpty {
                            Button("添加设备", systemImage: "plus") { adding = true }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.bordered).tint(nil)
                                .buttonBorderShape(.roundedRectangle)
                                .controlSize(.regular)
                                .help("添加设备")
                                .disabled(store.busy || authorizing)
                        }
                    }
                    if store.devices.isEmpty {
                        SettingsCard {
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("尚未添加设备").fontWeight(.medium)
                                    Text(store.needsAuthorization ? "添加设备后，按提示允许管理连接公钥。" : "添加允许连接这台 Mac 的设备。")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Button("添加设备", systemImage: "plus") { adding = true }
                                    .buttonStyle(.bordered).tint(nil)
                                    .disabled(store.busy || authorizing)
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            ForEach(store.devices) { device in
                                AuthorizedDeviceCard(device: device) { deviceActions(device) }
                            }
                        }.disabled(store.busy)
                    }
                    if let feedback = store.feedback { SettingsStatus(text: feedback, symbol: "checkmark.circle.fill", color: .green) }
                    if let error = store.error, !store.needsAuthorization { SettingsStatus(text: error, symbol: "exclamationmark.triangle", color: .orange) }
                }.padding(.vertical, 1)
            }
            Divider()
            HStack {
                if store.checkingSystem { ProgressView().controlSize(.mini) }
                Spacer()
                Button("完成") { dismiss() }.buttonBorderShape(.capsule).controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13)).padding(24)
        .onAppear { visible = true }
        .onDisappear { visible = false; awaitingSharingReturn = false; pendingRefresh = false }
        .task(id: refreshRequest) {
            let force = forceRefresh
            forceRefresh = false
            await refresh(force: force)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            completeSharingReturn()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            completeSharingReturn()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { notification in
            guard visible,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if application.bundleIdentifier == "com.apple.systempreferences" {
                awaitingSharingReturn = true
            } else if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                completeSharingReturn()
            }
        }
        .onChange(of: store.checkingSystem) { _, _ in drainRefreshRequest() }
        .onChange(of: store.busy) { _, _ in drainRefreshRequest() }
        .sheet(isPresented: $adding) { AddAuthorizedDeviceView(store: store) }
        .alert("无法完成操作", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(operationError ?? "") }
    }

    private func completeSharingReturn() {
        guard visible, awaitingSharingReturn else { return }
        awaitingSharingReturn = false
        requestRefresh()
    }

    private func requestRefresh() {
        pendingRefresh = true
        drainRefreshRequest()
    }

    private func drainRefreshRequest() {
        guard visible, pendingRefresh, !store.busy, !store.checkingSystem else { return }
        pendingRefresh = false
        forceRefresh = true
        refreshRequest &+= 1
    }

    private func openSharing() {
        awaitingSharingReturn = true
        SystemDialogs.openSharing()
    }

    private func refresh(force: Bool) async {
        async let system: Void = store.refreshSystemStatus(force: force)
        await store.refresh()
        await system
    }

    private func authorize() {
        authorizing = true
        Task {
            defer { authorizing = false }
            do {
                _ = try await store.authorize()
            } catch { operationError = error.localizedDescription }
        }
    }

    private func serviceRow(_ title: String, symbol: String, status: LocalSharingStatus) -> some View {
        let ready = status.availability == .enabled && status.account != .denied
        let color: Color = ready ? .green : (status.availability == .checking ? .secondary : .orange)
        return HStack(spacing: 12) {
            SettingsIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(status.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if status.availability == .checking {
                    ProgressView().controlSize(.mini).accessibilityLabel("正在检测" )
                } else if !ready || status.account == .unknown {
                    Button(status.availability == .disabled ? "去开启" : (status.account == .denied ? "去授权" : "去确认"), action: openSharing)
                        .disabled(store.checkingSystem)
                } else {
                    Label(status.title, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(color).fixedSize()
                }
            }
        }
    }

    @ViewBuilder private func deviceActions(_ device: AuthorizedDevice) -> some View {
        Button("重命名") {
            Task {
                if let name = await SystemDialogs.rename(device.name) {
                    do { try store.rename(device, to: name) } catch { operationError = error.localizedDescription }
                }
            }
        }
        Button("查看公钥") { Task { await SystemDialogs.showPublicKey(device) } }
        Divider()
        Button("移除设备", role: .destructive) {
            Task {
                guard await SystemDialogs.confirm(title: "移除\(device.name)？",
                    message: "这会撤销对应公钥的授权，使用同一把公钥的其他电脑也将无法建立新连接。其他公钥不受影响。", action: "移除设备", destructive: true) else { return }
                do { try await store.remove(device) } catch { operationError = error.localizedDescription }
            }
        }
    }
}
