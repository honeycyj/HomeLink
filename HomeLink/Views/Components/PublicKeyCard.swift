import SwiftUI

struct PublicKeyCard: View {
    let publicKey: String
    var title = "公钥"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(publicKey).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            CopyButton(value: publicKey, title: "复制公钥", copiedTitle: "已复制公钥")
            .controlSize(.small)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }
}
