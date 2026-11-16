import Foundation
import OSLog
import Security

private let keychainLog = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "keychain")

/// The Keychain for tokens: this device only, never synced, in the data
/// protection keychain (macOS too), where an item belongs to the app's
/// access group (its team and bundle id). Each build keeps its items under
/// its own bundle id, so a copy with another bundle id never even asks for
/// the real app's. Items older builds left in the macOS file-based
/// keychain, where any app can ask for them, are moved once and removed
/// there (`moveOldItem`); after that the old keychain is never read again.
/// Failures are logged, not ignored.
struct KeychainHelper: KeychainProviding {
    private let service: String
    /// Where "already moved" is kept: nil is the app's (or the tests')
    /// defaults, read only when needed.
    private let defaults: UserDefaults?
    /// The file-based keychain older builds wrote to: nil on iOS and under
    /// tests (they never touch this Mac's login keychain; they pass a fake).
    private let old: (any OldKeychain)?
    /// Where tokens live now.
    private let store: any NewKeychain
    /// What this launch already tried to move and couldn't.
    private let attempts: MoveAttempts

    init(service: String = KeychainHelper.defaultService, defaults: UserDefaults? = nil,
         old: (any OldKeychain)? = KeychainHelper.defaultOld, store: any NewKeychain = SystemKeychain.app,
         attempts: MoveAttempts = .launch) {
        self.service = service
        self.defaults = defaults
        self.old = old
        self.store = store
        self.attempts = attempts
    }

    /// Old items this launch couldn't move (refused, locked, a failed save
    /// or delete): each is tried once per launch, not on every read.
    final class MoveAttempts: @unchecked Sendable {
        static let launch = MoveAttempts()
        fileprivate var tried: Set<String> = []
        init() {}
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
        defaultOld(unitTesting: TestIsolation.isUnitTesting, arguments: ProcessInfo.processInfo.arguments)
    }

    /// The real old keychain, except under tests. Decided from the launch
    /// arguments, never `TestIsolation.isUITesting`: that one's own start
    /// makes a KeychainHelper, and asking it from here would recurse.
    static func defaultOld(unitTesting: Bool, arguments: [String]) -> (any OldKeychain)? {
        #if os(macOS)
        unitTesting || TestIsolation.isUITest(arguments: arguments) ? nil : FileKeychain()
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

    /// Signed with a team (CI's ad hoc signature isn't).
    static let signedWithTeam: Bool = {
        #if os(macOS)
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return false }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] != nil
        #else
        true
        #endif
    }()

    /// Replaces the item in place: a save that fails (a locked keychain)
    /// leaves the one that was there.
    @discardableResult
    func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        moveOldItem(key)
        let status = store.set(service: service, key: key, data: data)
        if status != errSecSuccess { keychainLog.error("Keychain save failed: \(status, privacy: .public)") }
        return status == errSecSuccess
    }

    func get(key: String) -> String? { read(key: key).value }

    /// The item, or why there is none: not there, or the keychain can't be
    /// read now (`unavailable`, which is never "signed out").
    func read(key: String) -> KeychainRead {
        moveOldItem(key)
        return store.read(service: service, key: key)
    }

    func delete(key: String) {
        moveOldItem(key)
        store.delete(service: service, key: key)
    }

    func deleteAll() {
        store.delete(service: service, key: nil)
    }

    /// One move at a time in this process: the old keychain's prompt switch
    /// is the process's, and two moves of one token would race.
    private static let moveLock = NSLock()

    /// An item an older build left in the file-based keychain under this
    /// build's service moves to the protected keychain and is removed there.
    /// Only one this build can read without the system asking (it wrote it);
    /// one another build wrote, or a locked keychain, is left alone and
    /// asked about again next launch. The protected copy, when there already
    /// is one, is kept: it's the one the app reads (old item dates aren't
    /// compared). Once the old
    /// item is gone (or there was none), never again. A build without the
    /// protected keychain moves nothing: it would only move the token to
    /// another name in the same file-based keychain.
    private func moveOldItem(_ key: String) {
        guard let old else { return }
        guard store.isProtected else { _ = Self.cantMove; return }
        let defaults = defaults ?? TestIsolation.defaults
        let flag = "keychain.oldItemMoved.protected.\(service).\(key)"
        Self.moveLock.withLock {
            guard !defaults.bool(forKey: flag), !attempts.tried.contains(flag) else { return }
            switch old.read(service: service, key: key) {
            case .notFound:
                defaults.set(true, forKey: flag)
            case let .refused(status):
                attempts.tried.insert(flag)
                keychainLog.error("An old keychain item couldn't be read without asking: \(status, privacy: .public)")
            case let .found(value, ref):
                switch store.read(service: service, key: key) {
                case .value: break
                case .notFound:
                    // Not saved: leave the old one where it is, still the user's.
                    guard store.add(service: service, key: key, data: Data(value.utf8)) == errSecSuccess else {
                        attempts.tried.insert(flag)
                        return
                    }
                case .unavailable:
                    // Can't tell whether there's a newer copy: next launch.
                    attempts.tried.insert(flag)
                    return
                }
                if old.remove(ref) { defaults.set(true, forKey: flag) } else { attempts.tried.insert(flag) }
            }
        }
    }

    /// Said once: a team-signed build without its access group (signed with
    /// the no-team entitlements) leaves old items where they are.
    private static let cantMove: Void = {
        if signedWithTeam {
            keychainLog.error("Signed with a team but without the keychain access group: tokens stay in the file-based keychain and old items are not moved")
        }
    }()
}

/// What a keychain read found.
enum KeychainRead: Equatable, Sendable {
    case value(String)
    case notFound
    /// It couldn't be read now (errSecInteractionNotAllowed: the Mac or
    /// device is locked, or not yet unlocked since it started). Never treat
    /// it as signed out or unpaired: ask again later.
    case unavailable(OSStatus)

    var value: String? { if case let .value(v) = self { v } else { nil } }
}

/// Where tokens live now.
protocol NewKeychain: Sendable {
    /// The data protection keychain (the app's access group), not the
    /// file-based one.
    var isProtected: Bool { get }
    func read(service: String, key: String) -> KeychainRead
    /// Adds the item only if there's none.
    func add(service: String, key: String, data: Data) -> OSStatus
    /// Replaces the item in place, or adds it.
    func set(service: String, key: String, data: Data) -> OSStatus
    /// One item, or with no key all of the service's.
    func delete(service: String, key: String?)
}

/// The system keychain: the data protection one when this build has its
/// access group; otherwise (no team) the file-based one, under a name of its
/// own, never the one older builds used, so it can't reach those items.
struct SystemKeychain: NewKeychain {
    let isProtected: Bool
    static let app = SystemKeychain(isProtected: KeychainHelper.dataProtection)

    /// Readable from the first unlock after the Mac starts until it shuts
    /// down, locked screen included: runs finish and push while you're
    /// away. Deliberately the same on iOS. Still this device only.
    static var accessible: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    private func base(_ service: String, _ key: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: isProtected ? service : "\(service).unsigned"]
        if let key { q[kSecAttrAccount as String] = key }
        if isProtected { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    func read(service: String, key: String) -> KeychainRead {
        var q = base(service, key)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let found = result as? [String: Any],
              let data = found[kSecValueData as String] as? Data, let value = String(data: data, encoding: .utf8) else {
            keychainLog.error("Keychain read failed: \(status, privacy: .public)")
            return .unavailable(status)
        }
        // Saved by an earlier build "when unlocked": move it to this class.
        if isProtected, found[kSecAttrAccessible as String] as? String != Self.accessible as String {
            let update = [kSecAttrAccessible as String: Self.accessible] as CFDictionary
            let moved = SecItemUpdate(base(service, key) as CFDictionary, update)
            if moved != errSecSuccess { keychainLog.error("Keychain class update failed: \(moved, privacy: .public)") }
        }
        return .value(value)
    }

    func add(service: String, key: String, data: Data) -> OSStatus {
        var q = base(service, key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = Self.accessible
        return SecItemAdd(q as CFDictionary, nil)
    }

    func set(service: String, key: String, data: Data) -> OSStatus {
        let update = [kSecValueData as String: data, kSecAttrAccessible as String: Self.accessible] as CFDictionary
        let status = SecItemUpdate(base(service, key) as CFDictionary, update)
        return status == errSecItemNotFound ? add(service: service, key: key, data: data) : status
    }

    func delete(service: String, key: String?) {
        SecItemDelete(base(service, key) as CFDictionary)
    }
}

/// What reading an old item found.
enum OldKeychainRead: Equatable {
    case found(value: String, ref: Data)
    case notFound
    /// The system wouldn't hand it over without asking (another build wrote
    /// it), or couldn't (locked).
    case refused(OSStatus)
}

/// The macOS file-based keychain older builds kept tokens in.
protocol OldKeychain {
    /// The item, only if this build can read it without the system asking.
    func read(service: String, key: String) -> OldKeychainRead
    /// Removes exactly the item `read` returned: true once it's gone.
    func remove(_ ref: Data) -> Bool
}

#if os(macOS)
/// Reads with the system's prompts turned off, so an item this build didn't
/// write is refused (errSecAuthFailed) instead of asking for the login
/// password. The switch is the process's, so it's off only for the call,
/// one call at a time.
struct FileKeychain: OldKeychain {
    private static let promptLock = NSLock()

    func read(service: String, key: String) -> OldKeychainRead {
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
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let found = result as? [String: Any],
              let data = found[kSecValueData as String] as? Data, let value = String(data: data, encoding: .utf8),
              let ref = found[kSecValuePersistentRef as String] as? Data else { return .refused(status) }
        return .found(value: value, ref: ref)
    }

    func remove(_ ref: Data) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecValuePersistentRef as String: ref,
                                kSecUseDataProtectionKeychain as String: false]
        let status = withoutPrompts { SecItemDelete(q as CFDictionary) }
        if status != errSecSuccess && status != errSecItemNotFound {
            keychainLog.error("An old keychain item couldn't be removed: \(status, privacy: .public)")
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func withoutPrompts(_ body: () -> OSStatus) -> OSStatus {
        Self.promptLock.withLock {
            var allowed: DarwinBoolean = true
            SecKeychainGetUserInteractionAllowed(&allowed)
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
            return body()
        }
    }
}
#endif

protocol KeychainProviding {
    @discardableResult func save(key: String, value: String) -> Bool
    func get(key: String) -> String?
    /// The item, or why there is none (`unavailable`: locked, ask later).
    func read(key: String) -> KeychainRead
    func delete(key: String)
    func deleteAll()
}

extension KeychainProviding {
    /// A store that can't be locked (tests' in-memory ones).
    func read(key: String) -> KeychainRead { get(key: key).map(KeychainRead.value) ?? .notFound }
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
        // No old keychain here: its default would ask isUITesting, which is starting.
        KeychainHelper(service: uiTestKeychainService, old: nil).deleteAll()
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
