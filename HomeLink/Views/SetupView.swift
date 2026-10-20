import SwiftUI

struct SetupView: View {
    @Bindable var store: DeviceStore
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var advanced = false
    @State private var reuseID: UUID?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Group {
            if let device = store.device(store.setupDeviceID) {
                AuthorizationView(store: store, device: device)
            } else {
                form
            }
        }
        .tint(.accentColor)
        .alert("无法添加设备", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("添加 Mac").font(.system(size: 18, weight: .semibold))
                Text("先添加设备，再复制公钥到 Studio。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            Form {
                TextField("名称", text: $name, prompt: Text("家庭 Mac Studio"))
                TextField("地址", text: $address, prompt: Text("home.example.com:2222"))
                TextField("用户名", text: $username, prompt: Text("studio"))
                SecureField("密码（可选）", text: .constant(""), prompt: Text("公钥连接无需填写"))
                    .disabled(true)
                    .help("默认使用公钥授权。备用密码登录暂未启用，密码不会收集或保存。")
                DisclosureGroup("高级选项", isExpanded: $advanced) {
                    TextField("SSH 端口", text: $port)
                        .help("22 是 SSH 标准默认端口；公网映射使用其他端口时请修改。地址中包含的端口优先于此设置。")
                    if !store.devices.isEmpty {
                        Picker("连接公钥", selection: $reuseID) {
                            ForEach(store.devices) { device in
                                Text("与 \(device.name) 使用相同公钥").tag(Optional(device.id))
                            }
                            Text("生成新的公钥").tag(nil as UUID?)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .formStyle(.columns)
            .disabled(busy || store.isLoading)

            VStack(alignment: .leading, spacing: 6) {
                Text("公钥只需在 Studio 授权一次，私钥由软件自动管理。")
                if let source = store.device(reuseID) {
                    Text("将与 \(source.name) 使用相同公钥；每台远程 Mac 仍需分别授权一次。")
                }
                Text("公网访问需先配置家庭网络入口。端口可填写在地址中，或在高级选项中修改。")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Button("取消") { dismissWindow(id: "add-device") }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(busy ? "正在准备" : "下一步", action: add)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(busy || store.isLoading || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || address.isEmpty || username.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { reuseID = store.devices.first?.id }
        .onChange(of: store.isLoading) { _, loading in
            if !loading { reuseID = store.devices.first?.id }
        }
    }

    private func add() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.add(name: name, address: address, username: username, port: port, reuseID: reuseID)
                name = ""; address = ""; username = ""; port = "22"
            } catch { self.error = error.localizedDescription }
        }
    }
}
