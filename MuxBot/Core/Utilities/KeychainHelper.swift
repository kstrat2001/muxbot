import Foundation
import OSLog
import Security

/// The Keychain for tokens: this device only, never synced. Uses the data
/// protection keychain (macOS too), and still finds items older builds put
/// in the macOS file-based keychain. Failures are logged, not ignored.
struct KeychainHelper: KeychainProviding {
    private let service: String
    private static let log = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "keychain")

    init(service: String = "com.darklyenergized.darkmuxapp") {
        self.service = service
    }

    private func base(_ key: String?, modern: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let key { q[kSecAttrAccount as String] = key }
        if modern { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    @discardableResult
    func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(key: key)
        var q = base(key, modern: true)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // Unsigned or ad-hoc builds can't use the data protection keychain.
            q[kSecUseDataProtectionKeychain as String] = nil
            status = SecItemAdd(q as CFDictionary, nil)
        }
        if status != errSecSuccess { Self.log.error("Keychain save failed: \(status, privacy: .public)") }
        return status == errSecSuccess
    }

    func get(key: String) -> String? {
        for modern in [true, false] {
            var q = base(key, modern: modern)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data { return String(data: data, encoding: .utf8) }
            if status != errSecItemNotFound && status != errSecMissingEntitlement {
                Self.log.error("Keychain read failed: \(status, privacy: .public)")
            }
        }
        return nil
    }

    func delete(key: String) {
        for modern in [true, false] { SecItemDelete(base(key, modern: modern) as CFDictionary) }
    }

    func deleteAll() {
        for modern in [true, false] { SecItemDelete(base(nil, modern: modern) as CFDictionary) }
    }
}

protocol KeychainProviding {
    @discardableResult func save(key: String, value: String) -> Bool
    func get(key: String) -> String?
    func delete(key: String)
    func deleteAll()
}
