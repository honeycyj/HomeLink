import Foundation

nonisolated struct RemoteDevice: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var publicKey: String
    var hasConnected = false
    var lastConnectedAt: Date?

    var address: String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return port == 22 ? hostPart : "\(hostPart):\(port)"
    }
}

struct Endpoint: Equatable, Sendable {
    let host: String
    let port: Int

    nonisolated init(address: String, fallbackPort: String = "22") throws {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw HomeLinkError.message("请填写 Mac 的域名或 IP 地址。") }
        var host = address
        var portText = fallbackPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("[") {
            guard let end = address.firstIndex(of: "]") else {
                throw HomeLinkError.message("IPv6 地址格式不正确，例如 [::1]:2222。")
            }
            host = String(address[address.index(after: address.startIndex)..<end])
            let suffix = address[address.index(after: end)...]
            if !suffix.isEmpty {
                guard suffix.first == ":" else { throw HomeLinkError.message("地址格式不正确。") }
                portText = String(suffix.dropFirst())
            }
        } else if address.filter({ $0 == ":" }).count == 1 {
            let parts = address.split(separator: ":", omittingEmptySubsequences: false)
            host = String(parts[0])
            portText = String(parts[1])
        }
        guard !host.isEmpty, !host.hasPrefix("-"),
              host.range(of: #"^[A-Za-z0-9._:\-]+$"#, options: .regularExpression) != nil else {
            throw HomeLinkError.message("请只填写域名或 IP，不要包含网址前缀、路径或空格。")
        }
        guard !portText.isEmpty, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(portText), (1...65535).contains(port) else {
            throw HomeLinkError.message("端口应为 1 到 65535 之间的数字。")
        }
        self.host = host
        self.port = port
    }

    nonisolated static func validateUsername(_ username: String) throws -> String {
        let value = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.\-]*$"#, options: .regularExpression) != nil else {
            throw HomeLinkError.message("请填写远程 Mac 的短用户名，例如 studio。")
        }
        return value
    }
}

enum HomeLinkError: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
