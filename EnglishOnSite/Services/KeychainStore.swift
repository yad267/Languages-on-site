import Foundation
import Security

enum KeychainStore {
    private static let service = "com.sputnik.englishonsite"
    private static let geminiAccount = "gemini_api_key"
    private static let elevenAccount = "elevenlabs_api_key"

    static func saveGeminiAPIKey(_ key: String) {
        save(account: geminiAccount, key: key)
    }

    static func loadGeminiAPIKey() -> String {
        load(account: geminiAccount)
    }

    static func hasGeminiAPIKey() -> Bool {
        !loadGeminiAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func saveElevenLabsAPIKey(_ key: String) {
        save(account: elevenAccount, key: key)
    }

    static func loadElevenLabsAPIKey() -> String {
        load(account: elevenAccount)
    }

    static func hasElevenLabsAPIKey() -> Bool {
        !loadElevenLabsAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func save(account: String, key: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            // Never log key material — only account label + OSStatus.
            print("[secrets] Keychain save FAIL account=\(account) status=\(status)")
        } else {
            print("[secrets] Keychain save OK account=\(account) bytes=\(data.count)")
        }
    }

    private static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
