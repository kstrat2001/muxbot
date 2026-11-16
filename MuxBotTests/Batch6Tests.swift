import Foundation
import Security
import Testing
@testable import MuxBot

struct PollBackoffTests {
    @Test func failuresBackOffAndSuccessResets() {
        var b = PollBackoff()
        #expect(b.delay == 3)
        b.failed(); #expect(b.delay == 6); #expect(!b.isUnreachable)
        b.failed(); #expect(b.delay == 12)
        b.failed(); #expect(b.delay == 24); #expect(b.isUnreachable, "three misses in a row")
        b.failed(); b.failed(); #expect(b.delay == 30, "capped")
        b.succeeded(); #expect(b.delay == 3); #expect(!b.isUnreachable)
    }
}

@Suite(.serialized)
struct KeychainTests {
    private let service = "com.darklyenergized.darkmuxapp.tests.\(UUID().uuidString)"

    @Test func saveReportsSuccessAndRoundTrips() {
        let k = KeychainHelper(service: service)
        #expect(k.save(key: "token", value: "abc") == true)
        #expect(k.get(key: "token") == "abc")
        #expect(k.save(key: "token", value: "def") == true, "replacing works")
        #expect(k.get(key: "token") == "def")
        k.delete(key: "token")
        #expect(k.get(key: "token") == nil)
    }

    /// Defaults of its own, so "already moved" starts false for each test.
    private func fresh() -> UserDefaults { UserDefaults(suiteName: "muxbot-keychain-\(UUID().uuidString)")! }

    /// A helper over in-memory keychains: the move never depends on how the
    /// test host is signed (CI signs with no team).
    private func helper(_ old: FakeOldKeychain, _ store: FakeNewKeychain = FakeNewKeychain(),
                        defaults: UserDefaults? = nil, service: String? = nil,
                        launch: KeychainHelper.MoveAttempts = KeychainHelper.MoveAttempts()) -> KeychainHelper {
        KeychainHelper(service: service ?? self.service, defaults: defaults ?? fresh(), old: old, store: store, attempts: launch)
    }

    @Test func anOldItemMovesOnceAndIsThenRemovedFromTheOldKeychain() {
        // Earlier builds wrote to the file-based keychain; the token must survive the move.
        let old = FakeOldKeychain()
        old.items[service + "/legacy"] = "old"
        let store = FakeNewKeychain()
        let k = helper(old, store)
        #expect(k.get(key: "legacy") == "old")
        #expect(old.items.isEmpty, "moved, so no other build can find it there")
        #expect(store.items[service + "/legacy"] == "old", "now in the protected keychain")
        #expect(k.get(key: "legacy") == "old")
        #expect(old.reads == 1, "looked once")
        k.delete(key: "legacy")
        #expect(k.get(key: "legacy") == nil)
    }

    @Test func theProtectedCopyWinsOverAnOldOneAndTheOldOneIsRemoved() {
        let old = FakeOldKeychain()
        old.items[service + "/both"] = "stale"
        let store = FakeNewKeychain()
        store.items[service + "/both"] = "new"
        let k = helper(old, store)
        #expect(k.get(key: "both") == "new", "the protected copy is kept")
        #expect(old.items.isEmpty, "the old copy is gone too")
    }

    @Test func aFailedSaveLeavesTheOldItemAndTriesAgainNextLaunch() {
        let old = FakeOldKeychain()
        old.items[service + "/kept"] = "old"
        let store = FakeNewKeychain()
        store.failAdds = true
        let defaults = fresh()
        let k = helper(old, store, defaults: defaults)
        #expect(k.get(key: "kept") == nil)
        #expect(old.items[service + "/kept"] == "old", "never removed before the new copy is saved")
        store.failAdds = false
        #expect(k.get(key: "kept") == nil, "not again this launch")
        #expect(old.reads == 1)
        #expect(helper(old, store, defaults: defaults).get(key: "kept") == "old", "next launch: moved")
        #expect(old.items.isEmpty)
    }

    @Test(arguments: [errSecAuthFailed, errSecInteractionNotAllowed, errSecInvalidOwnerEdit])
    func anOldItemThisBuildCannotReadSilentlyIsLeftAloneAndTriedNextLaunch(status: OSStatus) {
        let old = FakeOldKeychain()
        old.items[service + "/theirs"] = "another build's"
        old.refusal = status
        let defaults = fresh()
        let k = helper(old, defaults: defaults)
        #expect(k.get(key: "theirs") == nil)
        #expect(k.save(key: "theirs", value: "mine"))
        k.delete(key: "theirs")
        _ = k.get(key: "theirs")
        #expect(old.items[service + "/theirs"] == "another build's", "never deleted: this build didn't read it")
        #expect(old.removed.isEmpty)
        #expect(old.reads == 1, "asked once this launch, not on every read")
        old.refusal = nil
        let next = helper(old, defaults: defaults)
        #expect(next.get(key: "theirs") == "another build's", "asked again next launch, and moved once readable")
        #expect(old.items.isEmpty)
    }

    @Test func aRefusedRemoveIsTriedAgainNextLaunch() {
        let old = FakeOldKeychain()
        old.items[service + "/stuck"] = "old"
        old.refuseRemove = true
        let defaults = fresh()
        let k = helper(old, defaults: defaults)
        #expect(k.get(key: "stuck") == "old")
        #expect(old.items[service + "/stuck"] == "old", "the delete was refused")
        old.refuseRemove = false
        _ = k.get(key: "stuck")
        #expect(old.reads == 1, "not again this launch")
        let next = helper(old, defaults: defaults)
        #expect(next.get(key: "stuck") == "old")
        #expect(old.items.isEmpty, "removed next launch")
        _ = helper(old, defaults: defaults).get(key: "stuck")
        #expect(old.reads == 2, "then done for good")
    }

    @Test func aLockedKeychainIsUnavailableNotEmpty() {
        let old = FakeOldKeychain()
        old.items[service + "/token"] = "old"
        let store = FakeNewKeychain()
        store.items[service + "/token"] = "mine"
        store.unavailable = errSecInteractionNotAllowed
        let defaults = fresh()
        let k = helper(old, store, defaults: defaults)
        #expect(k.read(key: "token") == .unavailable(errSecInteractionNotAllowed))
        #expect(k.get(key: "token") == nil)
        #expect(old.items[service + "/token"] == "old", "nothing moved or removed while it can't tell")
        store.unavailable = nil
        #expect(helper(old, store, defaults: defaults).read(key: "token") == .value("mine"))
    }

    @Test func theSystemsAnswerMapsToFoundNotFoundOrUnavailable() {
        let item: [String: Any] = [kSecValueData as String: Data("t".utf8)]
        #expect(SystemKeychain.result(status: errSecSuccess, found: item) == .value("t"))
        #expect(SystemKeychain.result(status: errSecItemNotFound, found: nil) == .notFound)
        // Locked (-25308): never "not there", which would sign you out.
        #expect(SystemKeychain.result(status: errSecInteractionNotAllowed, found: nil) == .unavailable(errSecInteractionNotAllowed))
        #expect(SystemKeychain.result(status: errSecMissingEntitlement, found: nil) == .unavailable(errSecMissingEntitlement))
        #expect(SystemKeychain.result(status: errSecSuccess, found: [:]) == .unavailable(errSecSuccess), "an answer without the data")
    }

    @Test func aSaveThatFailsKeepsTheTokenThatWasThere() {
        let store = FakeNewKeychain()
        store.items[service + "/token"] = "mine"
        store.failAdds = true
        let k = helper(FakeOldKeychain(), store)
        #expect(!k.save(key: "token", value: "newer"))
        #expect(store.items[service + "/token"] == "mine", "a failed save never deletes first")
    }

    @Test(.enabled(if: KeychainHelper.dataProtection)) func tokensStayReadableWhileTheScreenIsLocked() throws {
        // Saved "after first unlock": runs finish and push with the screen
        // locked. One saved by an earlier build ("when unlocked") is moved
        // to that class the first time it's read.
        let k = KeychainHelper(service: service, defaults: fresh(), old: nil)
        defer { k.deleteAll() }
        #expect(k.save(key: "new", value: "a"))
        #expect(try accessibility("new") == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "earlier", kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: Data("b".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        #expect(k.get(key: "earlier") == "b")
        #expect(try accessibility("earlier") == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    private func accessibility(_ key: String) throws -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        try #require(SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess)
        return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
    }

    @Test func afterTheFirstLookTheOldKeychainIsNeverReadAgain() {
        let defaults = fresh()
        let old = FakeOldKeychain()
        let store = FakeNewKeychain()
        let k = helper(old, store, defaults: defaults)
        #expect(k.get(key: "late") == nil, "nothing to move")
        old.items[service + "/late"] = "planted later"
        #expect(k.get(key: "late") == nil, "no fallback to the old keychain")
        #expect(k.save(key: "late", value: "mine"))
        k.delete(key: "late")
        #expect(helper(old, store, defaults: defaults).get(key: "late") == nil, "not on a later launch either")
        #expect(old.reads == 1)
        #expect(old.items[service + "/late"] == "planted later", "saving and deleting never reach it")
    }

    @Test func aBuildWithoutTheProtectedKeychainNeverMovesTheToken() {
        // A team build signed with the no-team entitlements would otherwise
        // move the real token into the weaker file-based name.
        let old = FakeOldKeychain()
        old.items[service + "/token"] = "the real token"
        let store = FakeNewKeychain()
        store.isProtected = false
        let k = helper(old, store)
        #expect(k.get(key: "token") == nil)
        #expect(old.reads == 0, "never even read")
        #expect(old.items[service + "/token"] == "the real token")
        #expect(store.items.isEmpty)
    }

    @Test func movesAtTheSameTimeHappenOnce() {
        let old = FakeOldKeychain()
        old.items[service + "/shared"] = "old"
        old.readDelay = 0.02
        let store = FakeNewKeychain()
        let k = helper(old, store)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in _ = k.get(key: "shared") }
        #expect(old.maxConcurrentReads == 1, "one at a time (the old keychain's prompt switch is the process's)")
        #expect(old.reads == 1)
        #expect(store.items[service + "/shared"] == "old")
    }

    @Test func aSecondServiceCanNeitherReadNorDeleteTheFirstsItems() {
        let other = "\(service).other"
        let old = FakeOldKeychain()
        old.items[service + "/token"] = "first's old"
        let first = KeychainHelper(service: service, defaults: fresh(), old: nil)
        let second = KeychainHelper(service: other, defaults: fresh(), old: old)
        #expect(first.save(key: "token", value: "first's"))
        defer { first.deleteAll() }
        #expect(second.get(key: "token") == nil)
        #expect(second.save(key: "token", value: "second's"))
        second.delete(key: "token")
        second.deleteAll()
        #expect(first.get(key: "token") == "first's")
        #expect(old.items[service + "/token"] == "first's old", "the second never reaches the first's old item")
    }

    @Test func eachBuildKeepsItsTokensUnderItsOwnBundleID() {
        #expect(KeychainHelper.service(bundleID: "com.darklyenergized.darkmuxapp") == "com.darklyenergized.darkmuxapp",
                "the app finds the items it already saved")
        #expect(KeychainHelper.service(bundleID: "com.example.forked-muxbot") == "com.example.forked-muxbot")
        #expect(KeychainHelper.service(bundleID: nil) != "com.darklyenergized.darkmuxapp")
        #expect(KeychainHelper.defaultService == "\(Bundle.main.bundleIdentifier ?? "").tests", "tests: the host app's own, apart")
    }

    @Test func testsNeverTouchThisMacsOldKeychain() {
        #expect(KeychainHelper.defaultOld == nil)
        // A UI-test launch is decided from its arguments alone: asking must
        // never start TestIsolation.isUITesting, whose own start makes a
        // KeychainHelper (that recursion crashed a -uiTesting launch).
        #expect(KeychainHelper.defaultOld(unitTesting: false, arguments: ["Mux Bot", "-uiTesting"]) == nil)
        #expect(KeychainHelper.defaultOld(unitTesting: false, arguments: ["Mux Bot", "-uiTestingEmpty"]) == nil)
        #if os(macOS)
        #expect(KeychainHelper.defaultOld(unitTesting: false, arguments: ["Mux Bot"]) != nil, "the app looks")
        #endif
    }

    @Test func aUITestLaunchNeverAsksIsUITestingFromItsOwnStart() throws {
        // TestIsolation.isUITesting's start makes a KeychainHelper; if that
        // (or the default old keychain) asked isUITesting again, a
        // -uiTesting launch would crash in its own one-time start.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MuxBot/Core/Utilities/KeychainHelper.swift"), encoding: .utf8)
        func body(after marker: String) throws -> String {
            let start = try #require(source.range(of: marker))
            let rest = source[start.upperBound...]
            return String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
        }
        let opened = try #require(source.range(of: "static let isUITesting: Bool = {"))
        let closed = try #require(source[opened.upperBound...].range(of: "\n    }()\n"))
        let start = String(source[opened.upperBound..<closed.lowerBound])
        #expect(start.contains("old: nil"), "its KeychainHelper has no old keychain")
        for marker in ["static var defaultOld:", "static func defaultOld(unitTesting:"] {
            let decides = try body(after: marker)
            #expect(!decides.contains("isUITesting") && !decides.contains("isTesting"), "\(marker) decides from the arguments")
        }
    }

    @Test(.enabled(if: KeychainHelper.signedWithTeam)) func theAppIsSignedForTheDataProtectionKeychain() {
        // Without its access group the Mac app would keep tokens in the
        // file-based keychain, where another build can ask for them.
        #expect(KeychainHelper.dataProtection)
    }
}

/// The file-based keychain, in memory: "service/key" to value. With a
/// `refusal`, reads fail as the system does for an item another build
/// wrote (or a locked keychain).
final class FakeOldKeychain: OldKeychain, @unchecked Sendable {
    private let lock = NSLock()
    var items: [String: String] = [:]
    var refusal: OSStatus?
    var refuseRemove = false
    var readDelay: TimeInterval = 0
    private(set) var reads = 0
    private(set) var removed: [String] = []
    private(set) var maxConcurrentReads = 0
    private var reading = 0

    func read(service: String, key: String) -> OldKeychainRead {
        lock.withLock { reads += 1; reading += 1; maxConcurrentReads = max(maxConcurrentReads, reading) }
        if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }
        return lock.withLock {
            reading -= 1
            let id = "\(service)/\(key)"
            guard let value = items[id] else { return .notFound }
            if let refusal { return .refused(refusal) }
            return .found(value: value, ref: Data(id.utf8))
        }
    }

    func remove(_ ref: Data) -> Bool {
        lock.withLock {
            guard !refuseRemove else { return false }
            let id = String(decoding: ref, as: UTF8.self)
            removed.append(id)
            items[id] = nil
            return true
        }
    }
}

/// The keychain tokens live in now, in memory. `unavailable`: reads fail
/// as they do while the keychain can't be read (locked).
final class FakeNewKeychain: NewKeychain, @unchecked Sendable {
    private let lock = NSLock()
    var isProtected = true
    var failAdds = false
    var unavailable: OSStatus?
    var items: [String: String] = [:]

    func read(service: String, key: String) -> KeychainRead {
        lock.withLock {
            if let unavailable { return .unavailable(unavailable) }
            return items["\(service)/\(key)"].map(KeychainRead.value) ?? .notFound
        }
    }
    func add(service: String, key: String, data: Data) -> OSStatus {
        lock.withLock {
            guard !failAdds else { return errSecInteractionNotAllowed }
            guard items["\(service)/\(key)"] == nil else { return errSecDuplicateItem }
            items["\(service)/\(key)"] = String(decoding: data, as: UTF8.self)
            return errSecSuccess
        }
    }
    func set(service: String, key: String, data: Data) -> OSStatus {
        lock.withLock {
            guard !failAdds else { return errSecInteractionNotAllowed }
            items["\(service)/\(key)"] = String(decoding: data, as: UTF8.self)
            return errSecSuccess
        }
    }
    func delete(service: String, key: String?) {
        lock.withLock {
            if let key { items["\(service)/\(key)"] = nil } else { items = items.filter { !$0.key.hasPrefix("\(service)/") } }
        }
    }
}

/// Serves canned GitHub replies and records the requests.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [(status: Int, headers: [String: String], body: String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let reply: (status: Int, headers: [String: String], body: String) = Self.replies.isEmpty ? (404, [:], "") : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct GitHubCachingTests {
    private func client() -> RESTGitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return RESTGitHubClient(session: URLSession(configuration: config))
    }

    @Test func aSecondListAsksWithTheETagAndUsesTheCacheOn304() async throws {
        StubProtocol.requests = []
        StubProtocol.replies = [
            (200, ["ETag": "\"abc\""], #"[{"number":8,"title":"Gutter","labels":[]}]"#),
            (304, [:], ""),
        ]
        let gh = client()
        let first = try await gh.openIssues(repo: "kstrat2001/hcr")
        let second = try await gh.openIssues(repo: "kstrat2001/hcr")
        #expect(first.map(\.number) == [8])
        #expect(second.map(\.number) == [8], "304 serves the cached list")
        #expect(StubProtocol.requests.count == 2)
        #expect(StubProtocol.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
    }
}

@Suite(.serialized) @MainActor
struct IssueLookupTests {
    @Test func fixingAClosedIssueSaysSoInsteadOfDispatching() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        var closed = GitHubIssue(number: 8, title: "Gutter", body: "Open /pricing; selector `main > div`")
        closed.state = "closed"
        brain.github = MockGitHub(issues: [closed])
        await brain.send("fix #8", in: .bot(bot.id), store: store)
        #expect(bot.runs?.isEmpty ?? true)
        let reply = (store.conversation(for: .bot(bot.id)).messages ?? []).last { $0.role == .assistant }?.content ?? ""
        #expect(reply == "#8 is already closed on kstrat2001/hcr.")
    }
}

struct PreviewMessagingTests {
    @Test func picksArePostedToTheAppNotPolled() {
        // The page script sends a pick to the app's handler the moment it happens.
        #expect(BugReport.pageScript.contains("webkit.messageHandlers.\(BugReport.handlerName).postMessage"))
        #expect(!BugReport.pageScript.contains("return picked"))
        #expect(BugReport.pickerScript.contains("__muxSend("))
        #expect(!BugReport.pickerScript.contains("window.__muxPicked ="))
    }

    @Test func aPostedPickDecodes() throws {
        let json = #"{"label":"Human_Models","selector":"h1","tag":"h1","url":"/pricing","viewport":683,"left":20,"right":20,"width":643,"height":48,"paddingLeft":"0px","paddingRight":"0px","marginLeft":"0px","marginRight":"0px","x":20,"y":80}"#
        let element = try #require(BugReport.decodePick(json))
        #expect(element.selector == "h1")
        #expect(BugReport.decodePick("not json") == nil)
        #expect(BugReport.decodePick(42) == nil)
    }
}

/// A keychain that can be locked: reads say "unavailable", never "not
/// there", as the system's do while it can't read an item.
final class LockableKeychain: KeychainProviding, @unchecked Sendable {
    var items: [String: String] = [:]
    var locked = false
    func save(key: String, value: String) -> Bool { guard !locked else { return false }; items[key] = value; return true }
    func get(key: String) -> String? { read(key: key).value }
    func read(key: String) -> KeychainRead {
        if locked { return .unavailable(errSecInteractionNotAllowed) }
        return items[key].map(KeychainRead.value) ?? .notFound
    }
    func delete(key: String) { items[key] = nil }
    func deleteAll() { items = [:] }
}

@Suite(.serialized) @MainActor
struct LockedKeychainSignInTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "muxbot-locked-\(UUID().uuidString)")! }

    @Test func aLockedKeychainDuringRenewalKeepsTheSignInAndBothTokens() async {
        GitHubStub.reset()
        let keychain = LockableKeychain()
        keychain.items[GitHubAuth.tokenKey] = "old"
        keychain.items[GitHubAuth.refreshKey] = "r1"
        let auth = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, defaults: defaults(), sleep: { _ in })
        keychain.locked = true
        #expect(await auth.renewal() == .unreachable, "tried again later, not signed out")
        #expect(keychain.items[GitHubAuth.tokenKey] == "old")
        #expect(keychain.items[GitHubAuth.refreshKey] == "r1")
        guard case .signedIn = auth.state else { Issue.record("signed out: \(auth.state)"); return }
    }

    @Test func aSignInReadWhileLockedIsReadAgainOnceUnlocked() {
        let keychain = LockableKeychain()
        keychain.items[GitHubAuth.tokenKey] = "t"
        keychain.locked = true
        let store = defaults()
        store.set("kain-test", forKey: "github.user.login")
        let auth = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, defaults: store, sleep: { _ in })
        #expect(auth.state == .signedIn(login: "kain-test"), "a locked keychain isn't a signed-out one")
        #expect(auth.token == nil)
        keychain.locked = false
        #expect(auth.token == "t", "not remembered as missing")
    }

    @Test func aPairingReadWhileLockedIsReadAgainOnceUnlocked() {
        let keychain = LockableKeychain()
        keychain.items["darkmux.client.token"] = "p"
        keychain.locked = true
        let store = defaults()
        store.set("Mux Bot test", forKey: "darkmux.client.name")
        let connection = FleetConnection(keychain: keychain, defaults: store)
        #expect(connection.isPaired, "a locked keychain isn't an unpaired one")
        #expect(connection.token == nil)
        keychain.locked = false
        #expect(connection.token == "p")
    }
}
