import Foundation

@main
struct AuthorizationCommandTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("authorize.sh")
        let command = AuthorizationCommand.make(publicKey: "ssh-ed25519 AAAAExampleKey== HomeLink-test")
        try command.write(to: script, atomically: true, encoding: .utf8)
        func run() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            process.environment = ["HOME": folder.path, "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        try run()
        let authorized = folder.appendingPathComponent(".ssh/authorized_keys")
        let once = try Data(contentsOf: authorized)
        try run()
        let twice = try Data(contentsOf: authorized)
        precondition(once == twice)
        let restricted = "command=\"echo allowed\",no-agent-forwarding ssh-ed25519 AAAAExampleKey== different-comment\n"
        try restricted.write(to: authorized, atomically: true, encoding: .utf8)
        try run()
        let after = try String(contentsOf: authorized, encoding: .utf8)
        precondition(after == restricted)
        let notes = command.components(separatedBy: "HOMELINK_AUTHORIZE\n").last!
        precondition(notes.components(separatedBy: .newlines).allSatisfy { $0.isEmpty || $0.hasPrefix("#") })
        let mode = try FileManager.default.attributesOfItem(atPath: authorized.path)[.posixPermissions] as? NSNumber
        precondition(mode?.intValue == 0o600)
        print("PASS: repeatable public-key authorization, comment-independent matching, preserved options, security notes are nonexecuting comments")
    }
}
