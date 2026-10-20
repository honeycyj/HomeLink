import Foundation

/// One value is the source of truth for device, readiness, and failure.
enum ConnectionState: Equatable {
    case disconnected
    case connecting(RemoteDevice)
    case connected(RemoteDevice, port: UInt16)
    case disconnecting(RemoteDevice?)
    case failed(RemoteDevice, message: String)

    var activeDevice: RemoteDevice? {
        switch self {
        case .connecting(let device), .connected(let device, _): device
        case .disconnecting(let device): device
        case .disconnected, .failed: nil
        }
    }

    var isBusy: Bool {
        switch self { case .connecting, .disconnecting: true; default: false }
    }

    var localPort: UInt16? {
        if case .connected(_, let port) = self { return port }
        return nil
    }

    var errorMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }
}
