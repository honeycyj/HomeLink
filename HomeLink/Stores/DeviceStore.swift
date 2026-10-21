import AppKit
import Observation
import ServiceManagement

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
    var preferencesPage = PreferencesPage.overview
    private(set) var launchAtLoginStatus = SMAppService.mainApp.status
    private(set) var launchAtLoginError: String?
    var launchAtLogin: Bool { launchAtLoginStatus == .enabled }
    var launchAtLoginNeedsApproval: Bool { launchAtLoginStatus == .requiresApproval }
    var launchAtLoginDescription: String {
        switch launchAtLoginStatus {
        case .enabled: "已开启，登录这台 Mac 后自动运行。"
        case .requiresApproval: "等待系统批准，请在登录项中允许 HomeLink。"
        case .notRegistered: "登录后自动运行，方便连接与 DDNS 更新。"
        case .notFound: "系统未找到有效登录项，请将应用安装到应用程序后重试。"
        @unknown default: "无法确认登录项状态，请在系统设置中查看。"
        }
    }
    func refreshLaunchAtLogin() {
        launchAtLoginStatus = SMAppService.mainApp.status
        if launchAtLogin { launchAtLoginError = nil }
    }

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
        let directory = directory ?? HomeLinkStorage.directory
        repository = DeviceRepository(directory: directory)
        connection = ConnectionController(transport: transport ?? SSHConnection(),
                                          knownHosts: directory.appendingPathComponent("known_hosts"))
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
        launchAtLoginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLaunchAtLogin()
        } catch {
            refreshLaunchAtLogin()
            launchAtLoginError = "无法修改登录启动设置：\(error.localizedDescription)"
        }
    }

    func openConnectionLog() {
        let file = directory.appendingPathComponent("last-connection.log")
        Task {
            let exists = (try? await BackgroundExecutor.files.run { FileManager.default.fileExists(atPath: file.path) }) ?? false
            if exists { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
    }

}
