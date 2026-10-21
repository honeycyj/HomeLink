import SwiftUI

struct SettingsRootView: View {
    @Bindable var store: DeviceStore
    @Bindable var local: LocalAccessStore
    @Bindable var ddns: DDNSStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch store.preferencesPage {
            case .overview: overview
            case .connection:
                DevicePreferencesView(store: store, onBack: { store.preferencesPage = .overview })
            case .localAccess: LocalAccessView(store: local, back: { store.preferencesPage = .overview })
            case .ddns: DDNSPreferencesView(store: ddns, back: { store.preferencesPage = .overview })
            }
        }
        // Keep line lengths compact while allowing native screen-height zoom.
        .frame(minWidth: 520, idealWidth: 520, maxWidth: 640,
               minHeight: 520, idealHeight: 600, maxHeight: .infinity)
        .windowMinimizeBehavior(.enabled)
        .windowResizeBehavior(.enabled)
        .background(SettingsWindowControls().frame(width: 0, height: 0))
        .buttonStyle(SecondaryActionButtonStyle())
        .controlSize(.regular)
        .buttonBorderShape(.roundedRectangle)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HomeLink 设置").font(.title2.weight(.semibold))
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
            Form {
                Section("通用") { LoginAtStartupRow(store: store) }
                if !store.devices.isEmpty {
                    Section("远程连接") {
                        LabeledContent {
                            Button("设备设置") { store.preferencesPage = .connection }
                        } label: {
                            SettingsEntryLabel(title: "已保存的 Mac", symbol: "desktopcomputer")
                        }
                    }
                }
                Section("本机服务") {
                    LabeledContent {
                        Button("管理设备") { store.preferencesPage = .localAccess }
                            .accessibilityLabel("管理本机访问设备")
                    } label: {
                        SettingsEntryLabel(title: "本机访问", symbol: "desktopcomputer", color: .teal,
                                           detail: "允许其他 Mac 连接本机。")
                    }
                    LabeledContent {
                        Button("更新设置") { store.preferencesPage = .ddns }
                            .accessibilityLabel("设置 Cloudflare DDNS")
                    } label: {
                        SettingsEntryLabel(title: "Cloudflare DDNS", symbol: "globe", color: .orange,
                                           detail: ddns.configuration.enabled ? ddns.status : "未启用 · 公网 IP 改变时更新域名。")
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack { Spacer(); Button("完成") { dismiss() }.buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
                .padding(.horizontal, 24).padding(.vertical, 16)
        }
    }
}
