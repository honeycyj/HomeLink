import SwiftUI

struct DevicePreferencesView: View {
    @Bindable var store: DeviceStore
    let onBack: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var error: String?
    @State private var saving = false

    private var selected: RemoteDevice? { store.device(store.settingsDeviceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsHeading(title: "设备设置") {
                guard !saving else { return }
                saving = true
                Task {
                    defer { saving = false }
                    do { try await save(); onBack() } catch { self.error = error.localizedDescription }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let selected {
                        Picker("设备", selection: Binding(get: { selected.id }, set: switchDevice)) {
                            ForEach(store.devices) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.menu).disabled(saving)
        
                        Form {
                            TextField("名称", text: $name)
                            TextField("地址", text: $address)
                            TextField("用户名", text: $username)
                        }
                        .formStyle(.columns).textFieldStyle(.roundedBorder)
                        .disabled(saving || store.activeID == selected.id)
                        if store.activeID == selected.id {
                            Text("断开连接后可修改设备信息。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        PublicKeyCard(publicKey: selected.publicKey).id(selected.id)
                        AuthorizationCommandCard(publicKey: selected.publicKey).id(selected.id)
                    } else {
                        Text("尚未添加设备。添加后，可以在这里修改连接信息并复制公钥。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    if let message = store.errorMessage {
                        Text(message).font(.system(size: 12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 1)
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await save(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .buttonBorderShape(.capsule).controlSize(.large)
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || store.isLoading)
            }
        }
        .padding(24)
        .buttonBorderShape(.roundedRectangle)
        .onAppear {
            if selected == nil { store.settingsDeviceID = store.devices.first?.id }
            load()
        }
        .onChange(of: store.settingsDeviceID) { _, _ in load() }
        .onChange(of: store.isLoading) { _, loading in
            if !loading && selected == nil { store.settingsDeviceID = store.devices.first?.id; load() }
        }
        .alert("无法保存修改", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save() async throws {
        guard let selected else { return }
        if name != selected.name || address != selected.address || username != selected.username {
            try await store.update(selected.id, name: name, address: address, username: username)
        }
    }

    private func switchDevice(_ id: UUID) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await save(); store.settingsDeviceID = id; load() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func load() {
        name = selected?.name ?? ""
        address = selected?.address ?? ""
        username = selected?.username ?? ""
    }
}
