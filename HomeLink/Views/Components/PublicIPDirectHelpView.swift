import SwiftUI

struct PublicIPDirectHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("公网 IP 直连设置").font(.headline)
            Text("开启代理时，查询结果可能是代理服务器的 IP。请让以下查询地址走家庭网络直连。")
            Text("Shadowrocket") .fontWeight(.medium)
            Text("1. 编辑当前使用的配置，将下方规则加入 [Rule] 顶部。\n2. 保存配置，使用「配置」规则模式并重新连接。\n3. 返回 HomeLink 点击「检测」。")
            Text(PublicIPDetector.rules)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            CopyButton(value: PublicIPDetector.rules, title: "复制直连规则", copiedTitle: "已复制规则")
            Divider()
            Text("优先使用 Amazon 和 OpenDNS，不足时尝试 ipify 与 ident.me。至少两个来源一致且没有冲突才会通过。")
            Text("首次启用前，请与路由器显示的家庭公网 IPv4 核对。HomeLink 不会修改代理配置。")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 360)
    }
}
