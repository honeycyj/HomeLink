import Foundation

/// Revision checks keep late background writes from re-enabling a disabled feature.
nonisolated final class DDNSConfigurationStorage: @unchecked Sendable {
    let directory: URL
    private var savedRevision: UInt64 = 0 // Accessed only on BackgroundExecutor.files.
    init(directory: URL) { self.directory = directory }
    func load() async throws -> DDNSConfiguration {
        try await BackgroundExecutor.files.run { [self] in
            let file = directory.appendingPathComponent("ddns.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return DDNSConfiguration() }
            return try JSONDecoder().decode(DDNSConfiguration.self, from: Data(contentsOf: file))
        }
    }
    func save(_ configuration: DDNSConfiguration, revision: UInt64) async throws {
        try await BackgroundExecutor.files.run { [self] in
            guard revision > savedRevision else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try AuthorizedKeysFile.atomicWrite(JSONEncoder().encode(configuration), to: directory.appendingPathComponent("ddns.json"))
            savedRevision = revision
        }
    }
}
