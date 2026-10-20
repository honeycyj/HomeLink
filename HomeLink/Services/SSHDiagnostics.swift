import Foundation

/// A bounded stderr reader prevents OpenSSH from blocking on a full pipe.
nonisolated final class SSHDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var reachedEOF = false
    private let file: URL
    private let writer = DispatchQueue(label: "local.homelink.diagnostics", qos: .utility)
    private var revision = 0
    private var writtenRevision = 0
    private var writes = 0
    private var pendingFlush: DispatchWorkItem? // writer-queue only
    let pipe = Pipe()

    init(directory: URL) throws {
        file = directory.appendingPathComponent("last-connection.log")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw HomeLinkError.message("无法创建连接诊断记录。")
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                self?.finish()
                handle.readabilityHandler = nil
                return
            }
            self?.append(chunk)
        }
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if data.count > 131_072 { data.removeFirst(data.count - 131_072) }
        revision += 1
        lock.unlock()
        writer.async { [weak self] in self?.scheduleFlush() }
    }

    private func scheduleFlush() {
        guard pendingFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.writeSnapshot() }
        pendingFlush = work
        writer.asyncAfter(deadline: .now() + .milliseconds(500), execute: work)
    }

    private func writeSnapshot() {
        pendingFlush?.cancel()
        pendingFlush = nil
        lock.lock()
        let version = revision
        let snapshot = data
        let needed = version > writtenRevision
        lock.unlock()
        guard needed else { return }
        do {
            try snapshot.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            lock.lock()
            writtenRevision = version
            writes += 1
            lock.unlock()
        } catch { /* Preserve the in-memory diagnostic if the disk becomes unavailable. */ }
    }

    var diskWriteCount: Int { lock.lock(); defer { lock.unlock() }; return writes }

    func flush() async {
        await withCheckedContinuation { continuation in
            writer.async { [self] in writeSnapshot(); continuation.resume() }
        }
    }

    static func make(directory: URL) async throws -> SSHDiagnostics {
        try await BackgroundExecutor.files.run { try SSHDiagnostics(directory: directory) }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    private func finish() {
        lock.lock()
        reachedEOF = true
        lock.unlock()
        writer.async { [weak self] in self?.writeSnapshot() }
    }

    private func isFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedEOF
    }

    func waitForEOF() async {
        for _ in 0..<25 {
            if isFinished() { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await flush()
    }

    deinit {
        pendingFlush?.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    static func failure(_ raw: String, deadlineReached: Bool = false) -> String {
        if raw.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || raw.contains("Host key verification failed") {
            return "这台 Mac 的身份发生了变化，已暂停连接。请确认是否重装了系统或地址指向了其他设备。原信任记录不会自动覆盖。"
        }
        if raw.contains("Load key") || raw.contains("no such identity") {
            return "系统 SSH 无法加载本机连接密钥。请查看本次连接诊断记录。"
        }
        if raw.contains("Permission denied") || raw.contains("No more authentication methods") {
            return "Studio 未接受本机公钥。请检查用户名，并确认公钥已加入该用户的 authorized_keys。"
        }
        if raw.contains("Could not resolve") { return "找不到这个地址，请检查域名或 IP。" }
        if raw.contains("Connection refused") { return "远程 Mac 拒绝了连接，请检查远程登录是否开启，以及地址和端口是否正确。" }
        if raw.contains("Address already in use") || raw.contains("Could not request local forwarding") {
            return "SSH 本地隧道创建失败，请重新连接。"
        }
        if raw.contains("Authenticated to") {
            return "SSH 身份验证已成功，但屏幕共享隧道未能保持连接。请查看本次连接诊断记录。"
        }
        if raw.contains("timed out") || deadlineReached {
            if raw.contains("Connection established") {
                return "已接通 SSH 端口，但握手或身份验证未在规定时间内完成。请查看本次连接诊断记录。"
            }
            return "连接 SSH 端口超时。请检查地址、端口，以及代理或 VPN 对 HomeLink 的网络规则。"
        }
        let detail = raw.split(separator: "\n").filter { !$0.hasPrefix("debug") }.suffix(3).joined(separator: "\n")
        return detail.isEmpty ? "SSH 进程已退出，请查看本次连接诊断记录。" : "连接已中断。\n\(detail.prefix(600))"
    }
}
