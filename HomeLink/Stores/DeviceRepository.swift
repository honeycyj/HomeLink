import Foundation
import Observation

@MainActor
@Observable
final class DeviceRepository {
  private(set) var devices: [RemoteDevice] = []
  private(set) var loadError: String?
  private(set) var isLoading = true
  let directory: URL
  @ObservationIgnored private let storage: DeviceFileStorage
  @ObservationIgnored private var revision = -1

  init(directory: URL) {
    self.directory = directory
    storage = DeviceFileStorage(directory: directory)
  }

  func load() async {
    do { publish(try await storage.load()) } catch {
      loadError = "无法读取已保存的设备，原文件已保留：\(error.localizedDescription)"
    }
    isLoading = false
  }

  func apply(_ mutation: DeviceMutation) async throws {
    guard loadError == nil else { throw HomeLinkError.message("设备文件读取失败，已阻止覆盖原文件。") }
    publish(try await storage.apply(mutation))
  }

  func replace(_ devices: [RemoteDevice]) async throws { try await apply(.replace(devices)) }

  private func publish(_ snapshot: DeviceSnapshot) {
    guard snapshot.revision >= revision else { return }
    revision = snapshot.revision
    devices = snapshot.devices
  }
}
