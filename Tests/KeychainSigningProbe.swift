import Foundation
import Security
import LocalAuthentication

// Run only through script/test_keychain_signing.sh. Uses a disposable item, never a device key.
let service = "local.homelink.HomeLink.signing-probe"
guard CommandLine.arguments.count == 3 else { exit(2) }
let action = CommandLine.arguments[1]
let account = CommandLine.arguments[2]
var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: service, kSecAttrAccount as String: account]
let status: OSStatus
if action == "create" {
    query[kSecValueData as String] = Data(account.utf8)
    status = SecItemAdd(query as CFDictionary, nil)
} else {
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
    if action == "delete" { status = SecItemDelete(query as CFDictionary) }
    else {
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, (result as? Data) != Data(account.utf8) { exit(3) }
    }
}
guard status == errSecSuccess else {
    fputs("Keychain signing probe failed: \(status)\n", stderr)
    exit(1)
}
#if SECOND_BUILD
print("PASS: second build accessed disposable Keychain item without authorization UI")
#else
print("PASS: first build created disposable Keychain item")
#endif
