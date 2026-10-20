import Foundation
import Darwin

/// A single attempt owns its process, lifeline, diagnostic stream, and temporary identity.
@MainActor
final class SSHSessionResources {
    let process = Process()
    let lifeline = Pipe()
    let diagnostics: SSHDiagnostics
    let key: URL
    var isReady = false
    private(set) var isClosing = false
    private var stopTask: Task<Void, Never>?

    init(key: URL, diagnostics: SSHDiagnostics) {
        self.key = key
        self.diagnostics = diagnostics
    }

    func removeTemporaryKey() async {
        await KeyStore.removeTemporaryDirectory(key.deletingLastPathComponent())
    }

    func stop() async {
        if let stopTask { await stopTask.value; return }
        isClosing = true
        process.terminationHandler = nil
        let process = process
        let task = Task {
            try? lifeline.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            await Task.detached {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while process.isRunning && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                if process.processIdentifier > 0 { process.waitUntilExit() }
            }.value
            await diagnostics.waitForEOF()
            await removeTemporaryKey()
        }
        stopTask = task
        await task.value
    }
}
