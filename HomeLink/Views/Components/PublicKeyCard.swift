import SwiftUI

struct PublicKeyCard: View {
    let publicKey: String
    var title = "公钥"

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(publicKey).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                CopyButton(value: publicKey, title: "复制公钥", copiedTitle: "已复制公钥")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: {
            Text(title).font(.headline)
        }
    }
}
