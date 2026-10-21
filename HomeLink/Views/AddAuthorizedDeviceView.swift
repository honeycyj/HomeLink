import SwiftUI

struct AddAuthorizedDeviceView: View {
    @Bindable var store: LocalAccessStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var key = ""
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加设备").font(.system(size: 18, weight: .semibold))
            Text("为要连接这台 Mac 的电脑取个名字，再粘贴它的公钥。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            LabeledContent("设备名称") { TextField("例如：公司 MacBook", text: $name).textFieldStyle(.roundedBorder) }
            SettingsCard {
                Text("公钥").fontWeight(.medium)
                TextEditor(text: $key).font(.system(size: 11, design: .monospaced)).frame(height: 90)
                    .accessibilityLabel("完整的 SSH 公钥")
                Text("粘贴完整的 ssh-ed25519 公钥，已有公钥不会重复添加。公钥只用于授权，私钥应始终留在客户端，不要粘贴到这里。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("仅授权当前账户 \(NSUserName())，保留其他公钥，不修改系统 SSH 安全策略。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("添加设备") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { if try await store.add(name: name, publicKey: key) { dismiss() } }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || name.isEmpty || key.isEmpty)
            }
        }.buttonStyle(SecondaryActionButtonStyle()).controlSize(.regular)
        .buttonBorderShape(.roundedRectangle)
        .font(.system(size: 13)).padding(24).frame(width: 520).disabled(store.busy)
        .interactiveDismissDisabled(saving || store.busy)
    }
}
