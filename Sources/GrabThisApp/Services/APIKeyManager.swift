import Foundation
import Security

/// Manages API keys for AI services.
/// Supports a bundled fallback key and user-provided keys stored in Keychain.
@MainActor
final class APIKeyManager {
    static let shared = APIKeyManager()

    private let keychainService = "com.grabthis.app.apikeys"
    private let geminiKeyAccount = "gemini-api-key"

    // Bundled key (obfuscated) - split into parts to avoid easy extraction
    // You should replace this with your actual API key, split into parts
    private let bundledKeyParts: [String] = [
        // Replace with your actual Gemini API key split into 4 parts
        // Example: "AIza" + "SyBx" + "1234" + "5678"
        "AIzaSyD2i", "qZDRY6alLJ", "kZYZgckU0_v", "YRwMEXQeo"
    ]

    private init() {}

    /// Get the active API key (user key if set, otherwise bundled)
    func getActiveKey() -> String {
        // First try user's key from Keychain
        if let userKey = getUserKey(), !userKey.isEmpty {
            return userKey
        }
        // Fall back to bundled key
        return getBundledKey()
    }

    /// Check if user has set their own key
    func hasUserKey() -> Bool {
        guard let key = getUserKey() else { return false }
        return !key.isEmpty
    }

    /// Get the bundled (free tier) key
    func getBundledKey() -> String {
        bundledKeyParts.joined()
    }

    /// Get user's API key from Keychain
    func getUserKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: geminiKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    /// Save user's API key to Keychain
    func setUserKey(_ key: String) -> Bool {
        // Delete existing key first
        deleteUserKey()

        guard !key.isEmpty else { return true }

        let data = key.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: geminiKeyAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Delete user's API key from Keychain
    @discardableResult
    func deleteUserKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: geminiKeyAccount
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if the current key is the bundled (free tier) key
    func isUsingBundledKey() -> Bool {
        !hasUserKey()
    }
}
