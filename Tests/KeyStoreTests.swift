import Foundation

@main
struct KeyStoreTests {
    @MainActor
    static func main() async throws {
        let id = UUID(), reusedID = UUID(), anotherID = UUID(), rejectedID = UUID(), cancelledID = UUID()
        let ids = [id, reusedID, anotherID, rejectedID, cancelledID]
        do {
            let publicKey = try await KeyStore.create(for: id)
            precondition(publicKey.hasPrefix("ssh-ed25519 "))
            let file = try await KeyStore.materialize(for: id)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let original = try Data(contentsOf: file)
            precondition(String(decoding: original, as: UTF8.self).hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
            let device = RemoteDevice(id: id, name: "Test", host: "localhost", port: 22, username: "test", publicKey: publicKey)
            let reused = try await KeyStore.reuse(from: device, for: reusedID)
            precondition(reused == publicKey)
            var changed = device
            changed.publicKey = publicKey.split(separator: " ").prefix(2).joined(separator: " ") + " changed-comment"
            _ = try await KeyStore.reuse(from: changed, for: anotherID)
            await KeyStore.remove(for: id)
            let copy = try await KeyStore.materialize(for: reusedID)
            defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
            let copied = try Data(contentsOf: copy)
            precondition(copied == original)
            var mismatch = device
            mismatch.id = reusedID
            mismatch.publicKey = "ssh-ed25519 AAAAWrong=="
            do {
                _ = try await KeyStore.reuse(from: mismatch, for: rejectedID)
                preconditionFailure("Mismatched identity was accepted")
            } catch is HomeLinkError { }
            let cancelled = Task { try await KeyStore.create(for: cancelledID) }
            cancelled.cancel()
            do { _ = try await cancelled.value; preconditionFailure("Cancelled key generation continued") }
            catch is CancellationError { }
            do {
                _ = try await KeyStore.materialize(for: cancelledID)
                preconditionFailure("Cancelled key generation left a Keychain item")
            } catch is HomeLinkError { }
        } catch {
            for id in ids { await KeyStore.remove(for: id) }
            throw error
        }
        for id in ids { await KeyStore.remove(for: id) }
        print("PASS: asynchronous Keychain access, Ed25519, permissions, same-key reuse, independent removal, cancellation cleanup")
    }
}
