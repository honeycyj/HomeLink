import Foundation

/// Isolates blocking platform APIs from MainActor without occupying a cooperative executor thread.
nonisolated final class BackgroundExecutor: Sendable {
  private let queue: DispatchQueue
  init(label: String) { queue = DispatchQueue(label: label, qos: .utility) }

  func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws
    -> Value
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result(catching: operation)) }
    }
  }

  static let files = BackgroundExecutor(label: "local.homelink.files")
  static let keychain = BackgroundExecutor(label: "local.homelink.keychain")
}
