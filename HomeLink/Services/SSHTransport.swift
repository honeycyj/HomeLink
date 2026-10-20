import Foundation

@MainActor
protocol SSHTransport: AnyObject {
    func connect(to device: RemoteDevice, knownHosts: URL,
                 onUnexpectedExit: @escaping @MainActor (String) -> Void) async throws -> UInt16
    func disconnect() async
}

