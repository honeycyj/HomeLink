import CryptoKit
import Darwin
import Foundation
import SystemConfiguration

/// Passive physical-LAN identity. Never enables UPnP or changes proxy/routing.
nonisolated enum DDNSNetworkIdentity {
    static func current() async throws -> String {
        try Task.checkCancellation()
        let identity = try await BackgroundExecutor.files.run {
            guard let store = SCDynamicStoreCreate(nil, "HomeLink.DDNSNetwork" as CFString, nil, nil),
                  let services = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/.*/IPv4"] as CFArray) as? [String: Any] else {
                throw HomeLinkError.message("无法读取当前家庭网络，已暂停更新。")
            }
            var identities = Set<String>()
            for value in services.values {
                guard let entry = value as? [String: Any],
                      let interface = entry["InterfaceName"] as? String, interface.hasPrefix("en"),
                      let router = entry["Router"] as? String,
                      let addresses = entry["Addresses"] as? [String],
                      let masks = entry["SubnetMasks"] as? [String] else { continue }
                for (local, mask) in zip(addresses, masks) {
                    var a = in_addr(), b = in_addr(), m = in_addr()
                    guard inet_pton(AF_INET, local, &a) == 1, inet_pton(AF_INET, router, &b) == 1,
                          inet_pton(AF_INET, mask, &m) == 1, m.s_addr != 0,
                          a.s_addr & m.s_addr == b.s_addr & m.s_addr, local != router else { continue }
                    guard let mac = gatewayMAC(in: entry, router: router) else {
                        throw HomeLinkError.message("系统尚未确认本地网关身份。请确认家庭网络已联网后重试，未修改 DNS。")
                    }
                    identities.insert(router + "|" + mac)
                }
            }
            guard !identities.isEmpty, identities.count <= 3 else {
                throw HomeLinkError.message("无法确定当前物理网络。请连接家庭 Wi-Fi 或有线网络后重新验证。")
            }
            let material = identities.sorted().joined(separator: "\n")
            return "external-v2:" + Data(SHA256.hash(data: Data(material.utf8))).base64EncodedString()
        }
        try Task.checkCancellation()
        return identity
    }

    static func gatewayMAC(in entry: [String: Any], router: String) -> String? {
        if entry["ARPResolvedIPAddress"] as? String == router,
           let value = entry["ARPResolvedHardwareAddress"] as? String, let mac = canonicalMAC(value) { return mac }
        guard let signature = entry["NetworkSignature"] as? String else { return nil }
        let parts = signature.split(separator: ";").map(String.init)
        guard parts.contains("IPv4.Router=" + router),
              let value = parts.first(where: { $0.hasPrefix("IPv4.RouterHardwareAddress=") }) else { return nil }
        return canonicalMAC(String(value.dropFirst("IPv4.RouterHardwareAddress=".count)))
    }

    static func canonicalMAC(_ value: String) -> String? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }),
              parts.contains(where: { UInt8($0, radix: 16) != 0 }) else { return nil }
        return parts.map { String(format: "%02x", UInt8($0, radix: 16)!) }.joined(separator: ":")
    }
}

/// Fixed system utilities, no shell, credentials, or installed dependencies.
nonisolated enum DDNSCommandOutput {
    static func read(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("HomeLinkDDNS-\(UUID().uuidString)")
        do {
            let result = try await ProcessRunner.run(executable, arguments: arguments, outputFile: file, timeout: timeout)
            let text = try await BackgroundExecutor.files.run {
                let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
                guard let size, size.intValue <= 4096 else { throw HomeLinkError.message("网络检测响应异常，已暂停更新。") }
                return try String(contentsOf: file, encoding: .utf8)
            }
            _ = try? await BackgroundExecutor.files.run { try FileManager.default.removeItem(at: file) }
            guard result.status == 0 else { throw HomeLinkError.message("网络检测未成功，请检查直连规则及网络连接，未修改 DNS。") }
            try Task.checkCancellation()
            return text
        } catch {
            _ = try? await BackgroundExecutor.files.run { try FileManager.default.removeItem(at: file) }
            throw error
        }
    }
}
