import Foundation
import Observation

@MainActor @Observable
final class LocalAccessStore {
    private(set) var devices: [AuthorizedDevice] = []
    private(set) var busy = false
    private(set) var needsAuthorization = true
    private(set) var sharing = LocalSharingSnapshot()
    private(set) var checkingSystem = false
    var error: String?
    var feedback: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var names: [String: String]
    @ObservationIgnored private let directoryOverride: URL?
    @ObservationIgnored private let confirmation: @MainActor () async -> Bool
    @ObservationIgnored private let detectSharing: @Sendable () async -> LocalSharingSnapshot
    @ObservationIgnored private var lastSystemCheck: ContinuousClock.Instant?
    private static let consentKey = "localAccess.keyManagementConsent.v1"
    #if DEBUG
    @ObservationIgnored private var previewOnly = false
    func installPreviewDevices() {
        previewOnly = true; needsAuthorization = false
        devices = ["公司 MacBook", "我的 MacBook Air"].enumerated().compactMap { index, name in
            let wire = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + Data(repeating: UInt8(index + 1), count: 32)
            guard let key = try? SSHPublicKey(pasted: "ssh-ed25519 \(wire.base64EncodedString()) Preview-\(index)") else { return nil }
            return AuthorizedDevice(key: key, name: name)
        }
    }
    #endif

    init(defaults: UserDefaults = .standard, directory: URL? = nil, confirmation: @escaping @MainActor () async -> Bool = SystemDialogs.confirmLocalKeyManagement,
         detectSharing: @escaping @Sendable () async -> LocalSharingSnapshot = { await LocalSharingDetector().detect() }) {
        self.defaults = defaults
        directoryOverride = directory
        self.confirmation = confirmation
        self.detectSharing = detectSharing
        names = defaults.dictionary(forKey: "localAccess.names") as? [String: String] ?? [:]
        needsAuthorization = !defaults.bool(forKey: Self.consentKey)
    }

    func refreshSystemStatus(force: Bool = false) async {
        guard !Task.isCancelled, !checkingSystem else { return }
        if !force, let lastSystemCheck, lastSystemCheck.duration(to: .now) < .seconds(5) { return }
        checkingSystem = true
        defer { checkingSystem = false }
        let snapshot = await detectSharing()
        guard !Task.isCancelled else { return }
        sharing = snapshot
        lastSystemCheck = .now
    }

    func refresh() async {
        #if DEBUG
        if previewOnly { return }
        #endif
        guard !Task.isCancelled, !busy else { return }
        guard defaults.bool(forKey: Self.consentKey) else {
            devices = []; needsAuthorization = true; error = nil
            return
        }
        busy = true; defer { busy = false }
        do {
            let keys = try await withAuthorizedKeys { try AuthorizedKeysFile.read(directory: $0) }
            try Task.checkCancellation()
            devices = keys.map { key in
                AuthorizedDevice(key: key, name: names[key.identity] ?? (key.comment.isEmpty || key.comment.hasPrefix("HomeLink-") ? "已授权的 Mac" : String(key.comment.prefix(60))))
            }
            needsAuthorization = false; error = nil
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func authorize() async throws -> Bool {
        guard !busy else { throw HomeLinkError.message("正在读取设备，请稍后重试。") }
        guard await confirmation() else { return false }
        defaults.set(true, forKey: Self.consentKey)
        needsAuthorization = false
        await refresh()
        if let error { throw HomeLinkError.message(error) }
        return true
    }

    func add(name: String, publicKey: String) async throws -> Bool {
        guard !busy else { throw HomeLinkError.message("正在保存，请稍后重试。") }
        let key = try SSHPublicKey(pasted: publicKey)
        let name = try Self.validName(name)
        if needsAuthorization {
            guard try await authorize() else { return false }
        }
        busy = true
        do {
            let added = try await withAuthorizedKeys { try AuthorizedKeysFile.add(key, directory: $0) }
            if names[key.identity] == nil { names[key.identity] = name; saveNames() }
            feedback = added ? "设备已添加，可以从那台 Mac 连接。" : "这台设备已授权，无需重复添加。"
            error = nil; busy = false
            await refresh()
            return true
        } catch { busy = false; throw error }
    }

    func rename(_ device: AuthorizedDevice, to name: String) throws {
        names[device.id] = try Self.validName(name)
        saveNames()
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index].name = names[device.id]! }
    }

    func remove(_ device: AuthorizedDevice) async throws {
        #if DEBUG
        if previewOnly { devices.removeAll { $0.id == device.id }; return }
        #endif
        guard !busy else { throw HomeLinkError.message("正在保存，请稍后重试。") }
        busy = true
        do {
            try await withAuthorizedKeys { try AuthorizedKeysFile.remove(identity: device.id, directory: $0) }
            names.removeValue(forKey: device.id); saveNames(); busy = false
            await refresh()
        } catch { busy = false; throw error }
    }

    private func withAuthorizedKeys<T: Sendable>(_ operation: @escaping @Sendable (URL) throws -> T) async throws -> T {
        guard defaults.bool(forKey: Self.consentKey) else {
            throw HomeLinkError.message("请先允许 HomeLink 管理连接公钥。")
        }
        let override = directoryOverride
        return try await BackgroundExecutor.files.run {
            let directory = try override ?? LocalAccount.home.appendingPathComponent(".ssh", isDirectory: true)
            return try operation(directory)
        }
    }

    private static func validName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw HomeLinkError.message("请填写 1 到 80 个字符的设备名称。") }
        return name
    }
    private func saveNames() { defaults.set(names, forKey: "localAccess.names") }
}
