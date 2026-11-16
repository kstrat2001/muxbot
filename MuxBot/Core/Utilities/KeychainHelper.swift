import Foundation
import OSLog
import Security

/// The Keychain for tokens: this device only, never synced, in the data
/// protection keychain (macOS too), where an item belongs to the app that
/// saved it (its team and bundle id). Each build keeps its items under its
/// own bundle id, so a copy with another bundle id never even asks for the
/// real app's. Items older builds left in the macOS file-based keychain,
/// where any app can ask for them, are moved once and removed there
/// (`moveOldItem`); after that the old keychain is never read again.
/// Failures are logged, not ignored.
struct KeychainHelper: KeychainProviding {
    private let service: String
    /// Where "already moved" is kept: nil is the app's (or the tests')
    /// defaults, read only when needed.
    private let defaults: UserDefaults?
    /// The file-based keychain older builds wrote to: nil on iOS and under
    /// tests (they never touch this Mac's login keychain; they pass a fake).
    private let old: (any OldKeychain)?
    private static let log = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "keychain")

    init(service: String = KeychainHelper.defaultService, defaults: UserDefaults? = nil,
         old: (any OldKeychain)? = KeychainHelper.defaultOld) {
        self.service = service
        self.defaults = defaults
        self.old = old
    }

    /// This build's own items: its bundle id. Under tests (which run inside
    /// the app, with its bundle id) a separate one, so no test can read or
    /// delete the real tokens. A UI-test launch has its own too, emptied at
    /// each launch.
    static let defaultService = TestIsolation.isUITesting ? TestIsolation.uiTestKeychainService
        : TestIsolation.isTesting ? "\(appService).tests" : appService

    static let appService = service(bundleID: Bundle.main.bundleIdentifier)

    /// The service a build with this bundle id keeps its tokens under. A
    /// build with no bundle id gets one no app has.
    static func service(bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "muxbot.no-bundle-id" }
        return bundleID
    }

    static var defaultOld: (any OldKeychain)? {
        #if os(macOS)
        TestIsolation.isTesting ? nil : FileKeychain()
        #else
        nil
        #endif
    }

    /// Whether this build can use the data protection keychain: it needs
    /// the app's identifier in its signature (the keychain-access-groups
    /// entitlement, signed with a team). Always on iOS.
    static let dataProtection: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return ["com.apple.application-identifier", "keychain-access-groups"].contains {
            SecTaskCopyValueForEntitlement(task, $0 as CFString, nil) != nil
        }
        #else
        true
        #endif
    }()

    /// A build signed without a team can't use the data protection keychain
    /// and keeps its items in the file-based one, under a name of its own:
    /// never the one older builds used, so it can't reach those items.
    private var unsignedService: String { "\(service).unsigned" }

    private func base(_ key: String?, modern: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: modern ? service : unsignedService]
        if let key { q[kSecAttrAccount as String] = key }
        if modern { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    @discardableResult
    func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(key: key)
        let status = add(key, data, modern: Self.dataProtection)
        if status != errSecSuccess { Self.log.error("Keychain save failed: \(status, privacy: .public)") }
        return status == errSecSuccess
    }

    private func add(_ key: String, _ data: Data, modern: Bool) -> OSStatus {
        var q = base(key, modern: modern)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil)
    }

    func get(key: String) -> String? {
        moveOldItem(key)
        return read(key)
    }

    private func read(_ key: String) -> String? {
        var q = base(key, modern: Self.dataProtection)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return String(data: data, encoding: .utf8) }
        if status != errSecItemNotFound { Self.log.error("Keychain read failed: \(status, privacy: .public)") }
        return nil
    }

    func delete(key: String) {
        moveOldItem(key)
        SecItemDelete(base(key, modern: Self.dataProtection) as CFDictionary)
    }

    func deleteAll() {
        SecItemDelete(base(nil, modern: Self.dataProtection) as CFDictionary)
    }

    /// Once per key: an item an older build left in the file-based keychain
    /// under this build's service moves here and is removed there. Only one
    /// this build can read without asking (it wrote it; the old keychain
    /// would otherwise ask for the login password, and an item another build
    /// wrote is left alone). Never again after the first look.
    /// A build without the data protection keychain (no team) moves it to
    /// its own name in the file-based keychain, so the old name is free.
    private func moveOldItem(_ key: String) {
        guard let old else { return }
        let defaults = defaults ?? TestIsolation.defaults
        let flag = "keychain.oldItemChecked.\(service).\(key)"
        guard !defaults.bool(forKey: flag) else { return }
        if let item = old.read(service: service, key: key) {
            if read(key) == nil, let data = item.value.data(using: .utf8) {
                // Not moved: leave it where it is, still the user's.
                guard add(key, data, modern: Self.dataProtection) == errSecSuccess else { return }
            }
            old.remove(item.ref)
        }
        defaults.set(true, forKey: flag)
    }
}

/// The macOS file-based keychain older builds kept tokens in.
protocol OldKeychain {
    /// The item, only if this build can read it without the system asking.
    func read(service: String, key: String) -> (value: String, ref: Data)?
    /// Removes exactly the item `read` returned.
    func remove(_ ref: Data)
}

#if os(macOS)
/// Reads with the system's prompts turned off, so an item this build didn't
/// write is refused (errSecAuthFailed) instead of asking for the login
/// password. The switch is the process's, so it's on only for the call.
struct FileKeychain: OldKeychain {
    func read(service: String, key: String) -> (value: String, ref: Data)? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnPersistentRef as String: true,
        ]
        var result: AnyObject?
        let status = withoutPrompts { SecItemCopyMatching(q as CFDictionary, &result) }
        guard status == errSecSuccess, let found = result as? [String: Any],
              let data = found[kSecValueData as String] as? Data, let value = String(data: data, encoding: .utf8),
              let ref = found[kSecValuePersistentRef as String] as? Data else { return nil }
        return (value, ref)
    }

    func remove(_ ref: Data) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecValuePersistentRef as String: ref,
                                kSecUseDataProtectionKeychain as String: false]
        _ = withoutPrompts { SecItemDelete(q as CFDictionary) }
    }

    private func withoutPrompts(_ body: () -> OSStatus) -> OSStatus {
        var allowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return body()
    }
}
#endif

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
    static let uiTestKeychainService = "\(KeychainHelper.appService).uitests"

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
