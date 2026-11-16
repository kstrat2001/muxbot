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

    @Test func anOldItemMovesOnceAndIsThenRemovedFromTheOldKeychain() {
        // Earlier builds wrote to the file-based keychain; the token must survive the move.
        let old = FakeOldKeychain()
        old.items[service + "/legacy"] = "old"
        let k = KeychainHelper(service: service, defaults: fresh(), old: old)
        #expect(k.get(key: "legacy") == "old")
        #expect(old.items.isEmpty, "moved, so no other build can find it there")
        #expect(k.get(key: "legacy") == "old", "read from the new keychain now")
        #expect(old.reads == 1, "looked once")
        k.delete(key: "legacy")
        #expect(k.get(key: "legacy") == nil)
    }

    @Test func anOldCopyIsRemovedEvenWhenTheNewKeychainAlreadyHasOne() {
        let old = FakeOldKeychain()
        let k = KeychainHelper(service: service, defaults: fresh(), old: nil)
        #expect(k.save(key: "both", value: "new"))
        old.items[service + "/both"] = "stale"
        let moving = KeychainHelper(service: service, defaults: fresh(), old: old)
        #expect(moving.get(key: "both") == "new", "the newer one wins")
        #expect(old.items.isEmpty, "the stale copy is gone too")
        k.delete(key: "both")
    }

    @Test func anOldItemThisBuildCannotReadSilentlyIsLeftAlone() {
        let old = FakeOldKeychain()
        old.items[service + "/theirs"] = "another build's"
        old.unreadable = [service + "/theirs"]
        let k = KeychainHelper(service: service, defaults: fresh(), old: old)
        #expect(k.get(key: "theirs") == nil)
        #expect(k.save(key: "theirs", value: "mine"))
        k.delete(key: "theirs")
        #expect(old.items[service + "/theirs"] == "another build's", "never deleted: this build didn't write it")
        #expect(old.removed.isEmpty)
    }

    @Test func afterTheFirstLookTheOldKeychainIsNeverReadAgain() {
        let defaults = fresh()
        let old = FakeOldKeychain()
        let k = KeychainHelper(service: service, defaults: defaults, old: old)
        #expect(k.get(key: "late") == nil, "nothing to move")
        old.items[service + "/late"] = "planted later"
        #expect(k.get(key: "late") == nil, "no fallback to the old keychain")
        #expect(k.save(key: "late", value: "mine"))
        k.delete(key: "late")
        #expect(KeychainHelper(service: service, defaults: defaults, old: old).get(key: "late") == nil, "not on a later launch either")
        #expect(old.reads == 1)
        #expect(old.items[service + "/late"] == "planted later", "saving and deleting never reach it")
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
    }

    /// Signed with a team (not CI's ad hoc signature, which can't have an
    /// access group).
    private static var signedWithTeam: Bool {
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
    }

    @Test(.enabled(if: signedWithTeam)) func theAppIsSignedForTheDataProtectionKeychain() {
        // Without its access group the Mac app would keep tokens in the
        // file-based keychain, where another build can ask for them.
        #expect(KeychainHelper.dataProtection)
    }
}

/// The file-based keychain, in memory: "service/key" to value. An item in
/// `unreadable` is one the system would ask about (another build wrote it).
final class FakeOldKeychain: OldKeychain, @unchecked Sendable {
    var items: [String: String] = [:]
    var unreadable: Set<String> = []
    var reads = 0
    var removed: [String] = []

    func read(service: String, key: String) -> (value: String, ref: Data)? {
        reads += 1
        let id = "\(service)/\(key)"
        guard !unreadable.contains(id), let value = items[id] else { return nil }
        return (value, Data(id.utf8))
    }

    func remove(_ ref: Data) {
        let id = String(decoding: ref, as: UTF8.self)
        removed.append(id)
        items[id] = nil
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
