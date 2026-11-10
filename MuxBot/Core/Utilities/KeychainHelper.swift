import Foundation
import OSLog
import Security

/// The Keychain for tokens: this device only, never synced. Uses the data
/// protection keychain (macOS too), and still finds items older builds put
/// in the macOS file-based keychain. Failures are logged, not ignored.
struct KeychainHelper: KeychainProviding {
    private let service: String
    private static let log = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "keychain")

    init(service: String = KeychainHelper.defaultService) {
        self.service = service
    }

    /// The app's own item; under tests (which run inside the app, with its
    /// bundle id) a separate one, so no test can read or delete the real
    /// tokens. A UI-test launch has its own too, emptied at each launch.
    static let defaultService = TestIsolation.isUITesting ? TestIsolation.uiTestKeychainService
        : TestIsolation.isTesting ? "com.darklyenergized.darkmuxapp.tests" : "com.darklyenergized.darkmuxapp"

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

/// Tests run inside the app (its bundle id and container): whatever they
/// touch by default (defaults, the Keychain, `LocalBotState`, bug crops,
/// model settings, the store) is a separate copy, never the real app's.
/// One flag for all of it: unit tests, and the app as a UI test launches it
/// (`-uiTesting`, `-uiTestingEmpty`), which has no XCTest environment.
enum TestIsolation {
    /// Unit tests: the app is their host.
    static let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    /// A UI test launched the app. Its own defaults and Keychain item are
    /// emptied here, the first time anything asks, so each launch starts
    /// clean before either is read.
    static let isUITesting: Bool = {
        guard isUITest(arguments: ProcessInfo.processInfo.arguments) else { return false }
        UserDefaults.standard.removePersistentDomain(forName: uiTestDefaultsSuite)
        KeychainHelper(service: uiTestKeychainService).deleteAll()
        return true
    }()
    static let isTesting = isUnitTesting || isUITesting

    static let uiTestDefaultsSuite = "muxbot-uitests-app"
    static let uiTestKeychainService = "com.darklyenergized.darkmuxapp.uitests"

    /// Whether launch arguments are a UI test's.
    static func isUITest(arguments: [String]) -> Bool {
        arguments.contains("-uiTesting") || arguments.contains("-uiTestingEmpty")
    }

    /// The app's defaults, or a separate suite under tests (a UI-test
    /// launch has its own, apart from the unit tests').
    nonisolated(unsafe) static let defaults: UserDefaults = {
        if isUITesting { return UserDefaults(suiteName: uiTestDefaultsSuite) ?? UserDefaults() }
        if isUnitTesting { return UserDefaults(suiteName: "muxbot-tests-app") ?? .standard }
        return .standard
    }()
}
