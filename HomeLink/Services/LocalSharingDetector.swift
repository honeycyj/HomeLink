import Darwin
import Darwin.membership
import Foundation

/// Read-only checks. Never enables sharing, authenticates an SSH session or requests administrator access.
nonisolated struct LocalSharingDetector: Sendable {
    func detect() async -> LocalSharingSnapshot {
        async let configuration = launchConfiguration()
        async let sshResponding = Self.greeting(port: 22, prefix: "SSH-")
        async let screenResponding = Self.greeting(port: 5900, prefix: "RFB ")
        let access = try? await BackgroundExecutor(label: "local.homelink.sharing.accounts").run {
            (Self.accountAccess(service: "ssh"), Self.accountAccess(service: "screensharing"))
        }
        let (configured, ssh, screen) = await (configuration, sshResponding, screenResponding)
        return LocalSharingSnapshot(
            ssh: .resolve(configured: configured.0, responding: ssh, account: access?.0 ?? .unknown),
            screenSharing: .resolve(configured: configured.1, responding: screen, account: access?.1 ?? .unknown))
    }

    private func launchConfiguration() async -> (Bool?, Bool?) {
        guard let result = try? await capture("/bin/launchctl", ["print-disabled", "system"]), result.0 == 0,
              result.1.contains("disabled services = {") else { return (nil, nil) }
        let text = result.1
        return (await configured(text, label: "com.openssh.sshd", plist: "ssh.plist"),
                await configured(text, label: "com.apple.screensharing", plist: "com.apple.screensharing.plist"))
    }

    private func configured(_ text: String, label: String, plist: String) async -> Bool? {
        if let value = Self.override(in: text, label: label) { return value }
        // Missing overrides inherit the system launch job's default, provided the override query succeeded.
        return try? await BackgroundExecutor.files.run {
            let data = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/LaunchDaemons/" + plist))
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  values["Label"] as? String == label, let disabled = values["Disabled"] as? Bool else {
                throw HomeLinkError.message("无法读取系统共享状态。")
            }
            return !disabled
        }
    }

    static func override(in text: String, label: String) -> Bool? {
        guard text.contains("disabled services = {") else { return nil }
        let prefix = "\"" + label + "\" => "
        guard let line = text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix(prefix) }) else { return nil }
        switch String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) {
        case "enabled": return true
        case "disabled": return false
        default: return nil
        }
    }

    /// Read the greeting directly and close as soon as it is complete. Never sends application data.
    static func greeting(port: UInt16, prefix: String, timeout: TimeInterval = 0.6) async -> Bool {
        let cancellation = GreetingCancellation()
        return await withTaskCancellationHandler {
            (try? await BackgroundExecutor(label: "local.homelink.sharing.greeting").run {
                guard !cancellation.isCancelled else { return false }
                let descriptor = socket(AF_INET, SOCK_STREAM, 0)
                guard descriptor >= 0 else { return false }
                defer { close(descriptor) }
                guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return false }
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard connected == 0 || errno == EINPROGRESS else { return false }
                var connecting = connected != 0
                let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
                var data = Data()
                while !cancellation.isCancelled && ContinuousClock.now < deadline {
                    var event = pollfd(fd: descriptor, events: Int16(connecting ? POLLOUT : POLLIN), revents: 0)
                    let ready = poll(&event, 1, 25)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    if ready == 0 { continue }
                    if connecting {
                        var error: Int32 = 0
                        var size = socklen_t(MemoryLayout<Int32>.size)
                        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return false }
                        connecting = false
                        continue
                    }
                    var buffer = [UInt8](repeating: 0, count: 512)
                    let count = recv(descriptor, &buffer, buffer.count, 0)
                    if count < 0 {
                        if errno == EAGAIN || errno == EINTR { continue }
                        return false
                    }
                    guard count > 0, data.count + count <= 1024 else { return false }
                    data.append(contentsOf: buffer.prefix(count))
                    let text = String(decoding: data, as: UTF8.self)
                    if validGreeting(text, prefix: prefix) { return !cancellation.isCancelled }
                    if data.contains(10) { return false }
                }
                return false
            }) ?? false
        } onCancel: {
            cancellation.cancel()
        }
    }

    private final class GreetingCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    static func validGreeting(_ text: String, prefix: String) -> Bool {
        if prefix == "SSH-" { return text.split(separator: "\n").contains { $0.hasPrefix("SSH-2.0-") || $0.hasPrefix("SSH-1.99-") } }
        guard prefix == "RFB ", let first = text.components(separatedBy: "\n").first else { return false }
        let bytes = Array(first.utf8)
        return bytes.count == 11 && first.hasPrefix("RFB ") && bytes[7] == 46 &&
            [4, 5, 6, 8, 9, 10].allSatisfy { (48...57).contains(bytes[$0]) }
    }

    private func capture(_ executable: String, _ arguments: [String]) async throws -> (Int32, String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("HomeLinkSharing-\(UUID().uuidString)")
        do {
            let result = try await ProcessRunner.run(executable, arguments: arguments, outputFile: file, timeout: 4)
            let text = try await BackgroundExecutor.files.run {
                let data = try Data(contentsOf: file)
                guard data.count <= 65_536 else { throw HomeLinkError.message("系统状态响应过大。") }
                return String(decoding: data, as: UTF8.self)
            }
            _ = try? await BackgroundExecutor.files.run { try FileManager.default.removeItem(at: file) }
            return (result.status, text)
        } catch {
            _ = try? await BackgroundExecutor.files.run { try FileManager.default.removeItem(at: file) }
            throw error
        }
    }

    private static func accountAccess(service: String) -> LocalSharingStatus.AccountAccess {
        var user = UUID().uuid, member: Int32 = 0
        guard mbr_uid_to_uuid(getuid(), &user) == 0 else { return .unknown }
        let result = mbr_check_service_membership(&user, service, &member)
        if result == ENOENT { return .unrestricted }
        guard result == 0 else { return .unknown }
        return member == 1 ? .allowed : .denied
    }
}
