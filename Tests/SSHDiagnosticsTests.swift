import Foundation

@main
struct SSHDiagnosticsTests {
    static func main() async throws {
        precondition(SSHDiagnostics.failure("Connection timed out").contains("SSH 端口超时"))
        precondition(SSHDiagnostics.failure("debug1: Connection established.", deadlineReached: true).contains("握手或身份验证"))
        precondition(SSHDiagnostics.failure("Permission denied (publickey).").contains("未接受本机公钥"))
        precondition(SSHDiagnostics.failure("Authenticated to studio\nbind: Address already in use").contains("本地隧道创建失败"))
        precondition(SSHDiagnostics.failure("Authenticated to studio").contains("身份验证已成功"))
        precondition(!SSHDiagnostics.failure("").contains("超时"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = try await SSHDiagnostics.make(directory: directory)
        // Write more than a pipe buffer; the child must exit without waiting for a reader later.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "dd if=/dev/zero bs=1024 count=256 >&2 2>/dev/null; printf 'END-OF-SSH-TEST' >&2"]
        process.standardError = diagnostics.pipe
        try process.run()
        await Task.detached { process.waitUntilExit() }.value
        for _ in 0..<100 {
            if diagnostics.snapshot().hasSuffix("END-OF-SSH-TEST") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(process.terminationStatus == 0)
        precondition(diagnostics.snapshot().hasSuffix("END-OF-SSH-TEST"))
        await diagnostics.waitForEOF()
        let file = directory.appendingPathComponent("last-connection.log")
        let saved = try Data(contentsOf: file)
        precondition(saved.count <= 131_072)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
        let writesBefore = diagnostics.diskWriteCount
        for _ in 0..<1000 { diagnostics.append(Data("batch-line\n".utf8)) }
        await diagnostics.flush()
        let writesAfter = diagnostics.diskWriteCount - writesBefore
        precondition(writesAfter > 0 && writesAfter < 10)
        let final = try Data(contentsOf: file)
        precondition(final == Data(diagnostics.snapshot().utf8))
        print("Batched 1000 log chunks into \(writesAfter) disk writes")
        print("PASS: failure stages, empty stderr handling, continuous pipe draining, bounded owner-only log")
    }
}
