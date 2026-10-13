#if os(macOS)
import Foundation
import Security
import LocalAuthentication

/// Credentials are app-owned Keychain items. This API always forbids UI prompts.
public struct KeychainCredentialStore: Sendable {
    public let service: String
    public init(service: String) { self.service = service }
    private var query: [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: "http-api", kSecUseAuthenticationContext as String: context]
    }
    public func read() throws -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw failure(status) }
        return value
    }
    public func create(replace: Bool) throws -> String {
        if !replace, let existing = try read() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw failure(randomStatus) }
        let token = Data(bytes).base64EncodedString()
        let attributes = [kSecValueData as String: Data(token.utf8)]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = Data(token.utf8)
            let status = SecItemAdd(q as CFDictionary, nil)
            guard status == errSecSuccess else { throw failure(status) }
        } else if update != errSecSuccess { throw failure(update) }
        return token
    }
    public func revoke() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    public func authenticate(_ candidate: String) throws -> Bool {
        guard let secret = try read() else { return false }
        let a = Array(secret.utf8), b = Array(candidate.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }
    private func failure(_ status: OSStatus) -> AutomationFailure {
        .init("unavailable", "API credential access failed. Unlock Keychain and open the signed app, then retry.", details: ["keychainStatus": String(status)])
    }
}
#endif
