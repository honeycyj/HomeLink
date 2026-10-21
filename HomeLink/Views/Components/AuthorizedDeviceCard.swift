import SwiftUI

struct AuthorizedDeviceCard<Actions: View>: View {
    let device: AuthorizedDevice
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.title3).foregroundStyle(.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.body.weight(.medium)).lineLimit(1)
                    Text("已授权").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu(content: actions) { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(.secondary).fixedSize()
                    .help("\(device.name) 的操作").accessibilityLabel("\(device.name) 的操作")
            }.frame(minHeight: 44).padding(.horizontal, 6)
        }
        .contextMenu(menuItems: actions)
    }
}
