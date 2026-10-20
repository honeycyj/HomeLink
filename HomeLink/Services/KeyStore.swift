import Foundation
import Security

/// The private key lives in this application's keychain item, never in device metadata.
nonisolated enum KeyStore {
  private static let service = "local.homelink.HomeLink.ssh"

  static func create(for id: UUID) async throws -> String {
    let folder = try await BackgroundExecutor.files.run { try temporaryKeyDirectory() }
    do {
      let keyURL = folder.appendingPathComponent("identity")
      let result = try await ProcessRunner.run(
        "/usr/bin/ssh-keygen",
        arguments: [
          "-q", "-t", "ed25519", "-N", "", "-C", "HomeLink-\(id.uuidString)", "-f", keyURL.path,
        ])
      guard result.status == 0 else { throw HomeLinkError.message("无法创建连接密钥：\(result.error)") }
      let publicKey = try await BackgroundExecutor.keychain.run {
        let privateKey = try Data(contentsOf: keyURL)
        let publicKey = try String(
          contentsOf: keyURL.appendingPathExtension("pub"), encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: id.uuidString,
          kSecAttrLabel as String: "HomeLink SSH 私钥",
          kSecValueData as String: privateKey,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
        return publicKey
      }
      if Task.isCancelled {
        await remove(for: id)
        throw CancellationError()
      }
      await removeTemporaryDirectory(folder)
      return publicKey
    } catch {
      await removeTemporaryDirectory(folder)
      throw error
    }
  }

  static func materialize(for id: UUID) async throws -> URL {
    let file = try await BackgroundExecutor.keychain.run {
      var query = identity(for: id)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      guard status == errSecSuccess, let data = item as? Data else { throw keychainError(status) }
      let directory = try temporaryKeyDirectory()
      let file = directory.appendingPathComponent("identity")
      // The parent is private before the key is written. ssh requires an owner-only key file.
      guard
        FileManager.default.createFile(
          atPath: file.path, contents: data,
          attributes: [.posixPermissions: 0o600])
      else {
        try? FileManager.default.removeItem(at: directory)
        throw HomeLinkError.message("无法读取本机连接密钥。")
      }
      return file
    }
    if Task.isCancelled {
      await removeTemporaryDirectory(file.deletingLastPathComponent())
      throw CancellationError()
    }
    return file
  }

  static func remove(for id: UUID) async {
    _ = try? await BackgroundExecutor.keychain.run {
      SecItemDelete(identity(for: id) as CFDictionary)
    }
  }

  static func reuse(from device: RemoteDevice, for id: UUID) async throws -> String {
    let key = try await materialize(for: device.id)
    do {
      let publicFile = key.appendingPathExtension("pub")
      let result = try await ProcessRunner.run(
        "/usr/bin/ssh-keygen", arguments: ["-y", "-P", "", "-f", key.path],
        outputFile: publicFile)
      try await BackgroundExecutor.keychain.run {
        let derived = try String(contentsOf: publicFile, encoding: .utf8)
        guard result.status == 0,
          derived.split(whereSeparator: \.isWhitespace).prefix(2)
            .elementsEqual(device.publicKey.split(whereSeparator: \.isWhitespace).prefix(2))
        else {
          throw HomeLinkError.message("无法复用这份密钥，保存的公钥与私钥不匹配。原有密钥未改动。")
        }
        // Keep an independent Keychain item so removing either device cannot break the other.
        var query = identity(for: id)
        query[kSecAttrLabel as String] = "HomeLink SSH 私钥"
        query[kSecValueData as String] = try Data(contentsOf: key)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw keychainError(status) }
      }
      if Task.isCancelled {
        await remove(for: id)
        throw CancellationError()
      }
      await removeTemporaryDirectory(key.deletingLastPathComponent())
      return device.publicKey
    } catch {
      await removeTemporaryDirectory(key.deletingLastPathComponent())
      throw error
    }
  }

  private static func identity(for id: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
    ]
  }

  private static var temporaryRoot: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("HomeLinkKeys", isDirectory: true)
  }

  private static func temporaryKeyDirectory() throws -> URL {
    try FileManager.default.createDirectory(
      at: temporaryRoot, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let folder = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    return folder
  }

  /// Call only after acquiring the app's single-instance lock. Never touches stored Keychain keys.
  static func cleanupAbandonedTemporaryKeys() async {
    _ = try? await BackgroundExecutor.files.run {
      let folders =
        (try? FileManager.default.contentsOfDirectory(
          at: temporaryRoot, includingPropertiesForKeys: nil)) ?? []
      for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
        try? FileManager.default.removeItem(at: folder)
      }
    }

  }

  static func removeTemporaryDirectory(_ directory: URL) async {
    _ = try? await BackgroundExecutor.files.run {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private static func keychainError(_ status: OSStatus) -> HomeLinkError {
    let description = SecCopyErrorMessageString(status, nil) as String? ?? "错误 \(status)"
    return .message("无法访问本机密钥，请允许 HomeLink 使用它自己的钥匙串项目。\n\(description)")
  }
}
