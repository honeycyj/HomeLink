import SwiftUI

struct DeviceMenuView: View {
    @Bindable var store: DeviceStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var pendingRemoval: RemoteDevice?
    @State private var pendingConnection: RemoteDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("HomeLink")
                .font(.system(size: 15, weight: .semibold))
                .frame(height: 28)
                .padding(.horizontal, 10)

            if store.isLoading {
                ProgressView("正在读取设备").controlSize(.small).padding(10)
            } else if store.devices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("连接你的第一台 Mac").font(.system(size: 14, weight: .medium))
                    Text("添加设备，在 Studio 授权一次，以后点一下就能连接。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
            } else {
                sectionLabel("我的 Mac")
                if let active = store.activeDevice {
                    deviceRow(active)
                    if store.isConnecting {
                        menuAction("取消连接") { store.disconnect() }
                    } else {
                        menuAction("打开屏幕共享") { store.openScreenSharing() }
                        menuAction("断开连接") { store.disconnect() }
                    }
                    if store.devices.count > 1 {
                        menuDivider
                        sectionLabel("其他已保存的 Mac")
                    }
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.devices.filter { $0.id != store.activeID }) { deviceRow($0) }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: CGFloat(min(store.devices.filter { $0.id != store.activeID }.count, 5)) * 54)
            }

            if let error = store.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("暂时无法完成操作").fontWeight(.medium)
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("查看连接日志") { store.openConnectionLog() }.buttonStyle(SecondaryActionButtonStyle())
                    Button("知道了") { store.errorMessage = nil }.buttonStyle(SecondaryActionButtonStyle())
                }
                .font(.system(size: 12))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
            }

            menuDivider
            menuAction("添加 Mac") {
                store.setupDeviceID = nil
                show("add-device")
            }.disabled(store.isLoading)
            menuAction("设置") {
                store.preferencesPage = .overview
                store.settingsDeviceID = store.settingsDeviceID ?? store.devices.first?.id
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            menuAction("退出 HomeLink") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(width: 280)
        .tint(.accentColor)
        .alert("移除这台设备？", isPresented: removing) {
            Button("取消", role: .cancel) { pendingRemoval = nil }
            Button("移除设备", role: .destructive) {
                let device = pendingRemoval
                pendingRemoval = nil
                if let device {
                    Task {
                        do { try await store.remove(device) }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                }
            }
        } message: {
            Text("仅移除本机设备记录和对应私钥，不会删除 Studio 上的公钥授权。正在使用的连接也会断开。")
        }
        .alert("切换到\(pendingConnection?.name ?? "另一台 Mac")？", isPresented: switching) {
            Button("取消", role: .cancel) { pendingConnection = nil }
            Button("断开并连接") {
                if let device = pendingConnection { beginConnection(device) }
                pendingConnection = nil
            }
        } message: {
            Text("将断开当前 Mac 的连接与屏幕共享。设备资料会保留。")
        }
    }

    private var removing: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }
    private var switching: Binding<Bool> {
        Binding(get: { pendingConnection != nil }, set: { if !$0 { pendingConnection = nil } })
    }

    private func deviceRow(_ device: RemoteDevice) -> some View {
        DeviceMenuRow(device: device, isActive: store.activeID == device.id,
                  isConnecting: store.activeID == device.id && store.isConnecting,
                  action: { select(device) }) {
            if store.activeID == device.id {
                Button("断开连接") { store.disconnect() }
            } else {
                Button(device.hasConnected ? "连接" : "继续设置") { select(device) }
            }
            Button("设备设置") {
                store.preferencesPage = .connection
                store.settingsDeviceID = device.id
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Divider()
            Button("移除设备", role: .destructive) { pendingRemoval = device }
        }
    }

    private func select(_ device: RemoteDevice) {
        if store.activeID == device.id {
            if store.localPort != nil { store.openScreenSharing() }
            return
        }
        if !device.hasConnected {
            store.setupDeviceID = device.id
            show("add-device")
        } else if store.activeID != nil {
            pendingConnection = device
        } else { beginConnection(device) }
    }

    private func beginConnection(_ device: RemoteDevice) { Task { await store.connect(device) } }

    private func show(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    private var menuDivider: some View {
        Divider().padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private func menuAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13))
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}
