import Foundation
import Observation

/// Serializes session teardown/startup and ignores completions from superseded requests.
@MainActor
@Observable
final class ConnectionController {
    private(set) var state: ConnectionState = .disconnected
    @ObservationIgnored private let transport: any SSHTransport
    @ObservationIgnored private let knownHosts: URL
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var request = UUID()

    init(transport: (any SSHTransport)? = nil, knownHosts: URL) {
        self.transport = transport ?? SSHConnection()
        self.knownHosts = knownHosts
    }

    @discardableResult
    func connect(_ device: RemoteDevice) async -> Bool {
        guard !Task.isCancelled else { return false }
        let token = UUID()
        request = token
        let previous = operation
        previous?.cancel()
        state = .connecting(device)
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.request == token, !Task.isCancelled else { return }
            await self.transport.disconnect()
            guard self.request == token, !Task.isCancelled else { return }
            do {
                let port = try await self.transport.connect(to: device, knownHosts: self.knownHosts) { [weak self] message in
                    guard let self, self.request == token else { return }
                    self.state = .failed(device, message: message)
                }
                try Task.checkCancellation()
                guard self.request == token, case .connecting = self.state else { return }
                self.state = .connected(device, port: port)
            } catch is CancellationError {
                // The successor waits for this cleanup before it starts another SSH process.
                await self.transport.disconnect()
                if self.request == token { self.state = .disconnected }
            } catch {
                await self.transport.disconnect()
                if self.request == token { self.state = .failed(device, message: error.localizedDescription) }
            }
        }
        operation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.request == token { self?.disconnect() }
            }
        }
        return request == token && state.localPort != nil
    }

    func disconnect() {
        if case .disconnecting = state { return }
        let token = UUID()
        request = token
        let device = state.activeDevice
        let previous = operation
        previous?.cancel()
        state = .disconnecting(device)
        operation = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.transport.disconnect()
            if self.request == token { self.state = .disconnected }
        }
    }

    func shutdown() async {
        disconnect()
        await operation?.value
    }

    func dismissError() {
        if case .failed = state { state = .disconnected }
    }
}
