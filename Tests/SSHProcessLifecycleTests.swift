import Foundation
import Darwin

@main
struct SSHProcessLifecycleTests {
    @MainActor
    static func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("A process or temporary key was not cleaned up")
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HomeLink lifecycle \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func fixture(_ mode: String) throws -> (URL, URL, URL) {
            let folder = root.appendingPathComponent(UUID().uuidString)
            let session = folder.appendingPathComponent("session")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let key = session.appendingPathComponent("identity")
            FileManager.default.createFile(atPath: key.path, contents: Data("test-only".utf8), attributes: [.posixPermissions: 0o600])
            let executable = folder.appendingPathComponent("fake ssh")
            let code: String
            if mode == "fast" { code = "printf 'Permission denied (publickey).\\n' >&2; exit 1" }
            else { code = (mode == "stubborn" ? "trap '' TERM\n" : "trap 'exit 0' TERM\n") + "while :; do /bin/sleep 0.05; done" }
            try ("#!/bin/sh\nprintf '%s' \"$$\" > " + AuthorizationCommand.quote(folder.appendingPathComponent("child.pid").path) + "\n" + code)
                .write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return (folder, key, executable)
        }
        func child(_ folder: URL) throws -> pid_t {
            Int32(try String(contentsOf: folder.appendingPathComponent("child.pid"), encoding: .utf8))!
        }
        let device = RemoteDevice(id: UUID(), name: "Fixture", host: "fixture", port: 22, username: "fixture", publicKey: "test")

        // Live session, explicit disconnect, and idempotent shutdown.
        let (normal, normalKey, normalExe) = try fixture("normal")
        var exits = 0
        let transport = SSHConnection(executable: normalExe, materialize: { _ in normalKey },
                                      readiness: { _ in FileManager.default.fileExists(atPath: normal.appendingPathComponent("child.pid").path) })
        _ = try await transport.connect(to: device, knownHosts: normal.appendingPathComponent("known_hosts")) { _ in exits += 1 }
        let normalPID = try child(normal)
        precondition(kill(normalPID, 0) == 0 && !FileManager.default.fileExists(atPath: normalKey.path))
        await transport.disconnect()
        await transport.disconnect()
        precondition(kill(normalPID, 0) != 0 && exits == 0)

        // Early failure must be observed even before readiness and clean the key.
        let (fast, fastKey, fastExe) = try fixture("fast")
        let fastTransport = SSHConnection(executable: fastExe, timeout: .seconds(2), materialize: { _ in fastKey }, readiness: { _ in false })
        do {
            _ = try await fastTransport.connect(to: device, knownHosts: fast.appendingPathComponent("known_hosts")) { _ in exits += 1 }
            preconditionFailure("Early failure was missed")
        } catch { precondition(error.localizedDescription.contains("未接受本机公钥")) }
        precondition(!FileManager.default.fileExists(atPath: fastKey.path) && exits == 0)

        // A child ignoring SIGTERM must be killed within the shutdown deadline.
        let (stubborn, stubbornKey, stubbornExe) = try fixture("stubborn")
        let stubbornTransport = SSHConnection(executable: stubbornExe, timeout: .milliseconds(200), materialize: { _ in stubbornKey }, readiness: { _ in false })
        let start = ContinuousClock.now
        do {
            _ = try await stubbornTransport.connect(to: device, knownHosts: stubborn.appendingPathComponent("known_hosts")) { _ in exits += 1 }
            preconditionFailure("Timeout was missed")
        } catch { }
        precondition(start.duration(to: .now) < .seconds(5))
        let stubbornPID = try child(stubborn)
        precondition(kill(stubbornPID, 0) != 0 && !FileManager.default.fileExists(atPath: stubbornKey.path))

        // Cancellation in progress cleans both the child and the temporary key.
        let (cancelled, cancelledKey, cancelledExe) = try fixture("normal")
        let cancelledTransport = SSHConnection(executable: cancelledExe, materialize: { _ in cancelledKey }, readiness: { _ in false })
        let attempt = Task {
            try await cancelledTransport.connect(to: device, knownHosts: cancelled.appendingPathComponent("known_hosts")) { _ in exits += 1 }
        }
        try await wait { FileManager.default.fileExists(atPath: cancelled.appendingPathComponent("child.pid").path) }
        attempt.cancel()
        do { _ = try await attempt.value; preconditionFailure("Cancellation was ignored") }
        catch is CancellationError { }
        let cancelledPID = try child(cancelled)
        precondition(kill(cancelledPID, 0) != 0 && !FileManager.default.fileExists(atPath: cancelledKey.path))

        // Kill a real client parent with SIGKILL: the lifeline must reclaim its SSH child and key.
        let (crashed, crashedKey, crashedExe) = try fixture("stubborn")
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        parent.arguments = [crashed.path, crashedExe.path]
        try parent.run()
        try await wait { FileManager.default.fileExists(atPath: crashed.appendingPathComponent("child.pid").path) }
        let orphanPID = try child(crashed)
        kill(parent.processIdentifier, SIGKILL)
        await Task.detached { parent.waitUntilExit() }.value
        try await wait { kill(orphanPID, 0) != 0 && !FileManager.default.fileExists(atPath: crashedKey.path) }
        print("PASS: explicit disconnect, early failure, TERM escalation, cancellation, parent SIGKILL, temporary-key cleanup, paths containing spaces")
    }
}
