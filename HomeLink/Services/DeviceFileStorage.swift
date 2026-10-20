import Foundation

nonisolated enum DeviceMutation: Sendable {
  case replace([RemoteDevice])
  case add(RemoteDevice)
  case remove(UUID)
  case update(UUID, name: String, host: String, port: Int, username: String)
  case connected(UUID, Date)
}

nonisolated struct DeviceSnapshot: Sendable {
  let devices: [RemoteDevice]
  let revision: Int
}

/// Mutable fields are confined to this instance's serial executor.
nonisolated final class DeviceFileStorage: @unchecked Sendable {
  private let worker = BackgroundExecutor(label: "local.homelink.device-storage")
  private let directory: URL
  private var devices: [RemoteDevice] = []
  private var loaded = false
  private var loadFailed = false
  private var revision = 0

  init(directory: URL) { self.directory = directory }

  func load() async throws -> DeviceSnapshot {
    try await worker.run {
      try self.loadIfNeeded()
      return self.snapshot
    }
  }

  func apply(_ mutation: DeviceMutation) async throws -> DeviceSnapshot {
    try await worker.run {
      try self.loadIfNeeded()
      var copy = self.devices
      switch mutation {
      case .replace(let replacement): copy = replacement
      case .add(let device): copy.append(device)
      case .remove(let id): copy.removeAll { $0.id == id }
      case .update(let id, let name, let host, let port, let username):
        if let index = copy.firstIndex(where: { $0.id == id }) {
          copy[index].name = name
          copy[index].host = host
          copy[index].port = port
          copy[index].username = username
        }
      case .connected(let id, let date):
        if let index = copy.firstIndex(where: { $0.id == id }) {
          copy[index].hasConnected = true
          copy[index].lastConnectedAt = date
        }
      }
      let file = self.directory.appendingPathComponent("devices.json")
      try JSONEncoder().encode(copy).write(
        to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      self.devices = copy
      self.revision += 1
      return self.snapshot
    }
  }

  private var snapshot: DeviceSnapshot { DeviceSnapshot(devices: devices, revision: revision) }

  private func loadIfNeeded() throws {
    guard !loadFailed else { throw HomeLinkError.message("设备文件读取失败，已阻止覆盖原文件。") }
    guard !loaded else { return }
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let file = directory.appendingPathComponent("devices.json")
      if FileManager.default.fileExists(atPath: file.path) {
        devices = try JSONDecoder().decode([RemoteDevice].self, from: Data(contentsOf: file))
      }
      loaded = true
    } catch {
      loadFailed = true
      throw error
    }
  }
}
