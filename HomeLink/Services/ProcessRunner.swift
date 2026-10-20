import Darwin
import Foundation

nonisolated struct ProcessResult: Sendable {
  let status: Int32
  let error: String
}

/// General child-process execution: bounded stderr, cancellation, timeout and final reaping.
nonisolated enum ProcessRunner {
  static func run(
    _ executable: String, arguments: [String], outputFile: URL? = nil,
    timeout: TimeInterval = 40
  ) async throws -> ProcessResult {
    let cancellation = CancellationFlag()
    let worker = BackgroundExecutor(label: "local.homelink.process")
    return try await withTaskCancellationHandler {
      try await worker.run {
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        var output: FileHandle?
        if let outputFile {
          guard
            FileManager.default.createFile(
              atPath: outputFile.path, contents: nil,
              attributes: [.posixPermissions: 0o600])
          else {
            throw HomeLinkError.message("无法准备程序输出文件。")
          }
          output = try FileHandle(forWritingTo: outputFile)
        }
        defer { try? output?.close() }
        process.standardOutput = output ?? FileHandle.nullDevice
        let capture = ErrorCapture()
        process.standardError = capture.pipe
        try process.run()
        try? capture.pipe.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while process.isRunning && !cancellation.isCancelled && ContinuousClock.now < deadline {
          Thread.sleep(forTimeInterval: 0.025)
        }
        let expired = process.isRunning && !cancellation.isCancelled
        if process.isRunning {
          process.terminate()
          let stopDeadline = ContinuousClock.now.advanced(by: .seconds(1))
          while process.isRunning && ContinuousClock.now < stopDeadline { Thread.sleep(forTimeInterval: 0.025) }
          if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        capture.waitForEOF()
        if cancellation.isCancelled { throw CancellationError() }
        if expired { throw HomeLinkError.message("本机程序执行超时，已停止。") }
        return ProcessResult(status: process.terminationStatus, error: capture.text)
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }
    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }
  }

  private final class ErrorCapture: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    init() {
      pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let chunk = handle.availableData
        guard let self else { return }
        self.lock.lock()
        if chunk.isEmpty {
          self.finished = true
        } else {
          self.data.append(chunk)
          if self.data.count > 65_536 { self.data.removeFirst(self.data.count - 65_536) }
        }
        self.lock.unlock()
        if chunk.isEmpty { handle.readabilityHandler = nil }
      }
    }
    var text: String {
      lock.lock()
      defer { lock.unlock() }
      return String(decoding: data, as: UTF8.self)
    }
    private var isFinished: Bool {
      lock.lock()
      defer { lock.unlock() }
      return finished
    }
    func waitForEOF() {
      let deadline = Date().addingTimeInterval(0.5)
      while !isFinished && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }
    deinit { pipe.fileHandleForReading.readabilityHandler = nil }
  }
}
