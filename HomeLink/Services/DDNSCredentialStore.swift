import Foundation
import Security
import LocalAuthentication

nonisolated enum DDNSCredentialStore {
    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.homelink.HomeLink.cloudflare", kSecAttrAccount as String: "dns-token"]
    }
    static func load() async throws -> String {
        try await BackgroundExecutor.keychain.run {
            var query = identity
            query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            // Background timers never repeatedly prompt for the Keychain password.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            var value: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &value)
            guard status == errSecSuccess, let data = value as? Data, let token = String(data: data, encoding: .utf8) else {
                throw HomeLinkError.message("无法读取 DDNS 令牌，请在公网地址设置中重新验证。")
            }
            return token
        }
    }
    static func save(_ token: String) async throws {
        try await BackgroundExecutor.keychain.run {
            let changes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
            var status = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
            if status == errSecItemNotFound {
                var query = identity; query[kSecValueData as String] = Data(token.utf8)
                query[kSecAttrLabel as String] = "HomeLink Cloudflare DDNS"
                status = SecItemAdd(query as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw HomeLinkError.message("无法将 DDNS 令牌保存到钥匙串。") }
        }
    }
}

nonisolated protocol DDNSTokenStorage: Sendable {
    func load() async throws -> String
    func save(_ token: String) async throws
}
nonisolated struct KeychainDDNSTokenStorage: DDNSTokenStorage {
    func load() async throws -> String { try await DDNSCredentialStore.load() }
    func save(_ token: String) async throws { try await DDNSCredentialStore.save(token) }
}
