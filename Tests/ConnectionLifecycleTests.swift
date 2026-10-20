import Foundation
import Darwin

@MainActor
final class ControlledTransport: SSHTransport {
    struct Attempt {
        let device: RemoteDevice
        let completion: CheckedContinuation<UInt16, Error>
        let exit: @MainActor (String) -> Void
    }
    var attempts: [Attempt] = []
    var exits: [UUID: @MainActor (String) -> Void] = [:]
    var events: [String] = []

    func connect(to device: RemoteDevice, knownHosts: URL,
                 onUnexpectedExit: @escaping @MainActor (String) -> Void) async throws -> UInt16 {
        events.append("start:\(device.name)")
        exits[device.id] = onUnexpectedExit
        return try await withCheckedThrowingContinuation { continuation in
            attempts.append(Attempt(device: device, completion: continuation, exit: onUnexpectedExit))
        }
    }
    func complete(_ port: UInt16) { attempts.removeFirst().completion.resume(returning: port) }
    func disconnect() async { events.append("stop") }
}

@main
struct ConnectionLifecycleTests {
    @MainActor
    static func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for a lifecycle condition")
    }

    @MainActor
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func device(_ name: String) -> RemoteDevice {
            RemoteDevice(id: UUID(), name: name, host: "localhost", port: 22, username: "test", publicKey: "ssh-ed25519 fixture")
        }
        let a = device("A"), b = device("B"), c = device("C")
        let fake = ControlledTransport()
        let controller = ConnectionController(transport: fake, knownHosts: folder.appendingPathComponent("known_hosts"))
        let first = Task { await controller.connect(a) }
        await wait { fake.attempts.count == 1 }
        precondition(controller.state == .connecting(a) && controller.state.localPort == nil)
        controller.disconnect()
        precondition(controller.state == .disconnecting(a))
        let second = Task { await controller.connect(b) }
        await Task.yield()
        fake.complete(10001) // Simulate a late completion from a cancelled attempt.
        _ = await first.value
        await wait { fake.attempts.count == 1 && fake.attempts[0].device.id == b.id }
        precondition(controller.state == .connecting(b))
        fake.complete(10002)
        let secondConnected = await second.value
        precondition(secondConnected)
        precondition(controller.state == .connected(b, port: 10002))
        fake.exits[a.id]?("stale failure")
        precondition(controller.state == .connected(b, port: 10002))
        fake.exits[b.id]?("unexpected failure")
        precondition(controller.state.errorMessage == "unexpected failure" && controller.state.activeDevice == nil)
        controller.dismissError()
        precondition(controller.state == .disconnected)

        let third = Task { await controller.connect(c) }
        await wait { fake.attempts.count == 1 }
        third.cancel()
        fake.complete(10003)
        _ = await third.value
        await controller.shutdown()
        precondition(controller.state == .disconnected)
        precondition(fake.events.filter { $0.hasPrefix("start:") } == ["start:A", "start:B", "start:C"])

        // A failure delivered at the readiness boundary must not be overwritten by a late port.
        let boundary = Task { await controller.connect(a) }
        await wait { fake.attempts.count == 1 }
        fake.exits[a.id]?("exit at readiness")
        fake.complete(10004)
        let incorrectlyConnected = await boundary.value
        precondition(!incorrectlyConnected && controller.state.errorMessage == "exit at readiness")
        await controller.shutdown()

        // Superseded queued requests never start another process.
        let startA = Task { await controller.connect(a) }
        await wait { fake.attempts.count == 1 }
        let skipB = Task { await controller.connect(b) }
        await Task.yield()
        let startC = Task { await controller.connect(c) }
        await Task.yield()
        fake.complete(10005)
        _ = await startA.value
        _ = await skipB.value
        await wait { fake.attempts.count == 1 && fake.attempts[0].device.id == c.id }
        fake.complete(10006)
        _ = await startC.value
        precondition(controller.state == .connected(c, port: 10006))
        await controller.shutdown()

        // Extracting persistence keeps the old JSON representation and corrupt-file protection.
        let repository = DeviceRepository(directory: folder)
        await repository.load()
        try await repository.replace([a, b])
        let file = folder.appendingPathComponent("devices.json")
        let original = try Data(contentsOf: file)
        let restored = DeviceRepository(directory: folder)
        await restored.load()
        precondition(restored.devices == [a, b])
        let afterLoad = try Data(contentsOf: file)
        precondition(afterLoad == original)
        try Data("corrupt".utf8).write(to: file)
        let broken = DeviceRepository(directory: folder)
        await broken.load()
        do { try await broken.replace([]); preconditionFailure("Corrupt data was overwritten") }
        catch is HomeLinkError { }
        let preserved = try Data(contentsOf: file)
        precondition(preserved == Data("corrupt".utf8))
        print("PASS: explicit states, cancellation, serial switching, stale callbacks, unexpected exit, shutdown, compatible persistence")
    }
}
