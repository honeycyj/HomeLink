import AppKit
import Observation
import ServiceManagement
import UserNotifications

@MainActor
@Observable
final class DeviceStore {
    let repository: DeviceRepository
    let connection: ConnectionController
    private var operationError: String?
    @ObservationIgnored private var startup: Task<Void, Never>?
    private var modifyingDevices: Set<UUID> = []
    var setupDeviceID: UUID?
    var settingsDeviceID: UUID?
    var notificationsEnabled = UserDefaults.standard.bool(forKey: "connectionNotifications")
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    var devices: [RemoteDevice] { repository.devices }
    var activeID: UUID? { connection.state.activeDevice?.id }
    var isConnecting: Bool { connection.state.isBusy }
    var localPort: UInt16? { connection.state.localPort }
    var errorMessage: String? {
        get { operationError ?? repository.loadError ?? connection.state.errorMessage }
        set {
            operationError = newValue
            if newValue == nil { connection.dismissError() }
        }
    }
    private var directory: URL { repository.directory }

    init(directory: URL? = nil, transport: (any SSHTransport)? = nil, cleanupTemporaryKeys: Bool = false) {
        let directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("HomeLink", isDirectory: true)
        repository = DeviceRepository(directory: directory)
        connection = ConnectionController(transport: transport ?? SSHConnection(),
                                          knownHosts: directory.appendingPathComponent("known_hosts"))
        connection.onUnexpectedDisconnect = { [weak self] device in self?.notifyDisconnect(device.name) }
        startup = Task { [weak self] in
            if cleanupTemporaryKeys { await KeyStore.cleanupAbandonedTemporaryKeys() }
            await self?.repository.load()
        }
    }

    var isLoading: Bool { repository.isLoading }
    func prepare() async { await startup?.value }

    var activeDevice: RemoteDevice? { devices.first { $0.id == activeID } }
    func device(_ id: UUID?) -> RemoteDevice? { devices.first { $0.id == id } }

    func add(name: String, address: String, username: String, port: String, reuseID: UUID? = nil) async throws -> RemoteDevice {
        await prepare()
        guard repository.loadError == nil else { throw HomeLinkError.message("设备文件读取失败。为避免覆盖旧数据，请先恢复设备文件。") }
        let endpoint = try Endpoint(address: address, fallbackPort: port)
        let username = try Endpoint.validateUsername(username)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HomeLinkError.message("请给这台 Mac 起个名称。") }
        let id = UUID()
        let publicKey: String
        if let reuseID {
            guard let source = device(reuseID) else { throw HomeLinkError.message("选择的公钥已不存在，请重新选择。") }
            publicKey = try await KeyStore.reuse(from: source, for: id)
        } else {
            publicKey = try await KeyStore.create(for: id)
        }
        let device = RemoteDevice(id: id, name: name, host: endpoint.host, port: endpoint.port,
                                  username: username, publicKey: publicKey)
        do {
            try Task.checkCancellation()
            try await repository.apply(.add(device))
        } catch { await KeyStore.remove(for: id); throw error }
        setupDeviceID = id
        settingsDeviceID = id
        return device
    }

    func update(_ id: UUID, name: String, address: String, username: String) async throws {
        await prepare()
        guard activeID != id else { throw HomeLinkError.message("请先断开连接，再修改这台设备。") }
        guard modifyingDevices.insert(id).inserted else { throw HomeLinkError.message("这台设备正在保存，请稍后重试。") }
        defer { modifyingDevices.remove(id) }
        let endpoint = try Endpoint(address: address)
        let user = try Endpoint.validateUsername(username)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HomeLinkError.message("设备名称不能为空。") }
        try await repository.apply(.update(id, name: name, host: endpoint.host, port: endpoint.port, username: user))
    }

    func remove(_ device: RemoteDevice) async throws {
        await prepare()
        guard modifyingDevices.insert(device.id).inserted else { throw HomeLinkError.message("这台设备正在保存，请稍后重试。") }
        defer { modifyingDevices.remove(device.id) }
        if activeID == device.id { await connection.shutdown() }
        try await repository.apply(.remove(device.id))
        await KeyStore.remove(for: device.id)
        if setupDeviceID == device.id { setupDeviceID = nil }
        if settingsDeviceID == device.id { settingsDeviceID = devices.first?.id }
    }

    func connect(_ device: RemoteDevice) async {
        await prepare()
        guard !modifyingDevices.contains(device.id), let current = self.device(device.id) else {
            operationError = "这台设备正在保存或已移除，请稍后重试。"
            return
        }
        operationError = nil
        guard await connection.connect(current) else { return }
        do { try await repository.apply(.connected(device.id, .now)) }
        catch { operationError = "已连接，但未能保存最近连接时间。\n\(error.localizedDescription)" }
    }

    func disconnect() { connection.disconnect() }

    func shutdown() async { await connection.shutdown() }

    func openScreenSharing() {
        guard let port = localPort, let url = URL(string: "vnc://127.0.0.1:\(port)") else { return }
        if !NSWorkspace.shared.open(url) { errorMessage = "无法打开系统屏幕共享应用。" }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && SMAppService.mainApp.status == .requiresApproval {
                errorMessage = "请在系统设置 → 通用 → 登录项中允许 HomeLink 启动。"
            }
        } catch { errorMessage = "无法修改登录启动设置：\(error.localizedDescription)" }
    }

    func openConnectionLog() {
        let file = directory.appendingPathComponent("last-connection.log")
        Task {
            let exists = (try? await BackgroundExecutor.files.run { FileManager.default.fileExists(atPath: file.path) }) ?? false
            if exists { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
    }

    func setNotifications(_ enabled: Bool) async {
        do {
            let allowed = enabled ? try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) : false
            notificationsEnabled = allowed
            UserDefaults.standard.set(allowed, forKey: "connectionNotifications")
            if enabled && !allowed { errorMessage = "系统未允许通知，可在系统设置中为 HomeLink 开启。" }
        } catch { errorMessage = error.localizedDescription }
    }

    private func notifyDisconnect(_ name: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(name) 连接已断开"
        content.body = "点开 HomeLink 菜单栏，可以重新连接。"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
