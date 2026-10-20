import Foundation

@main
struct BackgroundServicesTests {
    @MainActor
    static func main() async throws {
        let worker = BackgroundExecutor(label: "homelink.test.background")
        var done = false
        let blocked = Task {
            let onBackground = try await worker.run {
                Thread.sleep(forTimeInterval: 0.2)
                return !Thread.isMainThread
            }
            precondition(onBackground)
            done = true
        }
        var ticks = 0
        while !done {
            ticks += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await blocked.value
        precondition(ticks >= 2)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = DeviceRepository(directory: folder)
        await repository.load()
        let a = RemoteDevice(id: UUID(), name: "A", host: "a.local", port: 22, username: "a", publicKey: "fixture")
        let b = RemoteDevice(id: UUID(), name: "B", host: "b.local", port: 22, username: "b", publicKey: "fixture")
        async let first: Void = repository.apply(.add(a))
        async let second: Void = repository.apply(.add(b))
        _ = try await (first, second)
        precondition(Set(repository.devices.map(\.id)) == Set([a.id, b.id]))
        async let edit: Void = repository.apply(.update(a.id, name: "Edited", host: "a.local", port: 46222, username: "a"))
        async let recent: Void = repository.apply(.connected(a.id, .now))
        _ = try await (edit, recent)
        let current = repository.devices.first { $0.id == a.id }!
        precondition(current.name == "Edited" && current.port == 46222 && current.hasConnected)
        let restored = DeviceRepository(directory: folder)
        await restored.load()
        precondition(restored.devices == repository.devices)
        do {
            _ = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "trap '' TERM; while :; do /bin/sleep 0.05; done"], timeout: 0.1)
            preconditionFailure("Process timeout was ignored")
        } catch is HomeLinkError { }
        let child = Task { try await ProcessRunner.run("/bin/sh", arguments: ["-c", "while :; do /bin/sleep 0.05; done"]) }
        try await Task.sleep(for: .milliseconds(100))
        child.cancel()
        do { _ = try await child.value; preconditionFailure("Process cancellation was ignored") }
        catch is CancellationError { }
        print("PASS: responsive MainActor during blocking work, serialized concurrent device changes, preserved edits, process timeout and cancellation")
    }
}
