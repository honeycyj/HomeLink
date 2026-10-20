import SwiftUI

struct AuthorizationCommandCard: View {
    let publicKey: String
    var explanation: String? = "连接中也可以复制。在其他 Mac 的目标账户终端执行一次；添加那台 Mac 时选择复用此公钥。"
    var prominent = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("远程 Mac 授权命令").fontWeight(.medium)
            if let explanation {
                Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if prominent {
                copyButton.buttonStyle(.borderedProminent)
            } else {
                copyButton
            }
            DisclosureGroup("查看命令与安全说明", isExpanded: $expanded) {
                ScrollView {
                    Text(AuthorizationCommand.make(publicKey: publicKey))
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .frame(height: 140).padding(.top, 6)
            }
        }
        .font(.system(size: 12))
    }

    private var copyButton: some View {
        CopyButton(value: AuthorizationCommand.make(publicKey: publicKey), title: "复制授权命令", copiedTitle: "已复制授权命令")
    }
}
