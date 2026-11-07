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

    @Test func anItemFromTheOldKeychainIsStillFound() {
        // Earlier builds wrote to the file-based keychain; the token must survive.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "legacy",
            kSecValueData as String: Data("old".utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
        let k = KeychainHelper(service: service)
        #expect(k.get(key: "legacy") == "old")
        k.delete(key: "legacy")
        #expect(k.get(key: "legacy") == nil, "deleted from wherever it was")
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
