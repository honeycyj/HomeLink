import Foundation
import Darwin

@MainActor
final class SSHConnection: SSHTransport {
    private var current: SSHSessionResources?
    private let executable: URL
    private let timeout: Duration
    private let materialize: @MainActor (UUID) async throws -> URL
    private let readiness: (UInt16) -> Bool

    init(executable: URL = URL(fileURLWithPath: "/usr/bin/ssh"), timeout: Duration = .seconds(45),
         materialize: @escaping @MainActor (UUID) async throws -> URL = KeyStore.materialize,
         readiness: @escaping (UInt16) -> Bool = SSHConnection.isListening) {
        self.executable = executable
        self.timeout = timeout
        self.materialize = materialize
        self.readiness = readiness
    }

    func connect(to device: RemoteDevice, knownHosts: URL,
                 onUnexpectedExit: @escaping @MainActor (String) -> Void) async throws -> UInt16 {
        await disconnect()
        try Task.checkCancellation()
        let port = try Self.availablePort()
        let key = try await materialize(device.id)
        let diagnostics: SSHDiagnostics
        do { diagnostics = try await SSHDiagnostics.make(directory: knownHosts.deletingLastPathComponent()) }
        catch {
            await KeyStore.removeTemporaryDirectory(key.deletingLastPathComponent())
            throw error
        }
        if Task.isCancelled {
            await KeyStore.removeTemporaryDirectory(key.deletingLastPathComponent())
            throw CancellationError()
        }
        let resources = SSHSessionResources(key: key, diagnostics: diagnostics)
        current = resources
        let process = resources.process
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SSHProcessSupervisor.script, "HomeLink SSH", key.deletingLastPathComponent().path,
                             executable.path] + Self.arguments(device: device, key: key, knownHosts: knownHosts, port: port)
        process.standardInput = resources.lifeline
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostics.pipe
        process.terminationHandler = { [weak self, weak resources] _ in
            Task { @MainActor [weak self, weak resources] in
                guard let self, let resources, self.current === resources,
                      resources.isReady, !resources.isClosing else { return }
                await resources.stop()
                guard self.current === resources else { return }
                self.current = nil
                onUnexpectedExit(SSHDiagnostics.failure(diagnostics.snapshot()))
            }
        }
        do {
            try process.run()
            try? resources.lifeline.fileHandleForReading.close()
            try? diagnostics.pipe.fileHandleForWriting.close()
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while process.isRunning && ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if readiness(port) {
                    try Task.checkCancellation()
                    guard process.isRunning, current === resources else { break }
                    resources.isReady = true
                    await resources.removeTemporaryKey()
                    try Task.checkCancellation()
                    guard process.isRunning, current === resources else { break }
                    return port
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let timedOut = process.isRunning
            await resources.stop()
            throw HomeLinkError.message(SSHDiagnostics.failure(diagnostics.snapshot(), deadlineReached: timedOut))
        } catch {
            await resources.stop()
            if current === resources { current = nil }
            if error is CancellationError { throw CancellationError() }
            if error is HomeLinkError { throw error }
            throw HomeLinkError.message("无法启动系统 SSH：\(error.localizedDescription)")
        }
    }

    func disconnect() async {
        guard let resources = current else { return }
        await resources.stop()
        if current === resources { current = nil }
    }

    private static func arguments(device: RemoteDevice, key: URL, knownHosts: URL, port: UInt16) -> [String] {
        ["-F", "/dev/null", "-N", "-T", "-i", key.path,
         "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
         "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\"\(knownHosts.path)\"",
         "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ExitOnForwardFailure=yes",
         "-o", "ConnectTimeout=30", "-o", "ConnectionAttempts=1",
         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
         "-o", "LogLevel=DEBUG1", "-o", "ForwardAgent=no",
         "-L", "127.0.0.1:\(port):127.0.0.1:5900", "-p", String(device.port),
         "-l", device.username, "--", device.host]
    }

    nonisolated private static func availablePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw HomeLinkError.message("无法建立本地连接入口。") }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw HomeLinkError.message("无法创建本地隧道，请稍后重试。") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) }
        }
        guard found == 0 else { throw HomeLinkError.message("无法分配本地端口。") }
        return UInt16(bigEndian: address.sin_port)
    }

    nonisolated private static func isListening(port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

}
