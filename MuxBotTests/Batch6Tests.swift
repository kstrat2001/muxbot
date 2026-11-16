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
                        defaults: UserDefaults? = nil, service: String? = nil) -> KeychainHelper {
        KeychainHelper(service: service ?? self.service, defaults: defaults ?? fresh(), old: old, store: store)
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

    @Test func aFailedSaveLeavesTheOldItemAndTriesAgain() {
        let old = FakeOldKeychain()
        old.items[service + "/kept"] = "old"
        let store = FakeNewKeychain()
        store.failAdds = true
        let defaults = fresh()
        let k = helper(old, store, defaults: defaults)
        #expect(k.get(key: "kept") == nil)
        #expect(old.items[service + "/kept"] == "old", "never removed before the new copy is saved")
        store.failAdds = false
        #expect(k.get(key: "kept") == "old", "tried again, and moved")
        #expect(old.items.isEmpty)
    }

    @Test(arguments: [errSecAuthFailed, errSecInteractionNotAllowed, errSecInvalidOwnerEdit])
    func anOldItemThisBuildCannotReadSilentlyIsLeftAloneAndTriedAgain(status: OSStatus) {
        let old = FakeOldKeychain()
        old.items[service + "/theirs"] = "another build's"
        old.refusal = status
        let k = helper(old)
        #expect(k.get(key: "theirs") == nil)
        #expect(k.save(key: "theirs", value: "mine"))
        k.delete(key: "theirs")
        #expect(old.items[service + "/theirs"] == "another build's", "never deleted: this build didn't read it")
        #expect(old.removed.isEmpty)
        let before = old.reads
        _ = k.get(key: "theirs")
        #expect(old.reads == before + 1, "a refusal (or a locked keychain) is asked about again, not given up on")
        old.refusal = nil
        #expect(k.get(key: "theirs") == "another build's", "readable now: moved")
        #expect(old.items.isEmpty)
    }

    @Test func aRefusedRemoveIsTriedAgain() {
        let old = FakeOldKeychain()
        old.items[service + "/stuck"] = "old"
        old.refuseRemove = true
        let k = helper(old)
        #expect(k.get(key: "stuck") == "old")
        #expect(old.items[service + "/stuck"] == "old", "the delete was refused")
        old.refuseRemove = false
        #expect(k.get(key: "stuck") == "old")
        #expect(old.items.isEmpty, "removed on the next look")
        let reads = old.reads
        _ = k.get(key: "stuck")
        #expect(old.reads == reads, "then done")
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

/// The keychain tokens live in now, in memory.
final class FakeNewKeychain: NewKeychain, @unchecked Sendable {
    private let lock = NSLock()
    var isProtected = true
    var failAdds = false
    var items: [String: String] = [:]

    func read(service: String, key: String) -> String? { lock.withLock { items["\(service)/\(key)"] } }
    func add(service: String, key: String, data: Data) -> OSStatus {
        lock.withLock {
            guard !failAdds else { return errSecInteractionNotAllowed }
            guard items["\(service)/\(key)"] == nil else { return errSecDuplicateItem }
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
