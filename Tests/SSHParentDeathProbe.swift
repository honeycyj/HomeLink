import Foundation

@main
struct SSHParentDeathProbe {
    static func main() throws {
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let executable = CommandLine.arguments[2]
let process = Process()
let lifeline = Pipe()
process.executableURL = URL(fileURLWithPath: "/bin/sh")
process.arguments = ["-c", SSHProcessSupervisor.script, "HomeLink SSH Test", folder.appendingPathComponent("session").path, executable]
process.standardInput = lifeline
process.standardOutput = FileHandle.nullDevice
process.standardError = FileHandle.nullDevice
try process.run()
try? lifeline.fileHandleForReading.close()
try String(process.processIdentifier).write(to: folder.appendingPathComponent("supervisor.pid"), atomically: true, encoding: .utf8)
withExtendedLifetime(lifeline) {
    while true { Thread.sleep(forTimeInterval: 0.1) }
}

    }
}
