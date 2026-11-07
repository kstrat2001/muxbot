import Foundation
import Testing
@testable import MuxBot

/// Answers GitHub requests from a queue per "METHOD path" and records
/// what was asked (no network).
final class GitHubStub: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var body: String }
    struct Seen { var method: String; var path: String; var body: [String: Any]?; var auth: String? }
    nonisolated(unsafe) static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) static var seen: [Seen] = []

    static func reset() { replies = [:]; seen = [] }
    static func on(_ key: String, _ status: Int = 200, _ body: String) { replies[key, default: []].append(Reply(status: status, body: body)) }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); var buf = Data(); var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&chunk, maxLength: chunk.count); if n <= 0 { break }; buf.append(chunk, count: n) }
            stream.close(); data = buf
        }
        var json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if json == nil, let d = data, let form = String(data: d, encoding: .utf8), form.contains("=") {
            json = Dictionary(uniqueKeysWithValues: form.split(separator: "&").map { kv in
                let p = kv.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                return (p[0], p.count > 1 ? p[1] : "")
            })
        }
        Self.seen.append(Seen(method: method, path: path, body: json, auth: request.value(forHTTPHeaderField: "Authorization")))
        let key = "\(method) \(path)"
        let reply = Self.replies[key]?.isEmpty == false ? Self.replies[key]!.removeFirst() : Reply(status: 404, body: #"{"message":"Not Found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MemoryKeychain: KeychainProviding, @unchecked Sendable {
    var items: [String: String] = [:]
    func save(key: String, value: String) -> Bool { items[key] = value; return true }
    func get(key: String) -> String? { items[key] }
    func delete(key: String) { items[key] = nil }
    func deleteAll() { items = [:] }
}

@Suite(.serialized) @MainActor
struct GitHubSignInTests {
    private func auth(_ keychain: MemoryKeychain = MemoryKeychain(), sleeps: SleepLog = SleepLog()) -> GitHubAuth {
        GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, sleep: { sleeps.log.append($0) })
    }

    final class SleepLog: @unchecked Sendable { var log: [Double] = [] }

    @Test func theDeviceFlowSignsInAndKeepsTheTokenOnThisDevice() async {
        GitHubStub.reset()
        GitHubStub.on("POST /login/device/code", 200, #"{"device_code":"dc1","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
        GitHubStub.on("POST /login/oauth/access_token", 200, #"{"error":"authorization_pending"}"#)
        GitHubStub.on("POST /login/oauth/access_token", 200, #"{"error":"slow_down","interval":10}"#)
        GitHubStub.on("POST /login/oauth/access_token", 200, #"{"access_token":"ghu_abc","token_type":"bearer","scope":""}"#)
        GitHubStub.on("GET /user", 200, #"{"login":"kstrat2001"}"#)
        let keychain = MemoryKeychain()
        let sleeps = SleepLog()
        let a = auth(keychain, sleeps: sleeps)
        var codes: [String] = []
        await a.signIn { code, _ in codes.append(code) }
        #expect(codes == ["WDJB-MJHT"])
        #expect(a.state == .signedIn(login: "kstrat2001"))
        #expect(keychain.items[GitHubAuth.tokenKey] == "ghu_abc")
        #expect(sleeps.log == [5, 5, 10], "waits the interval, then slows down when asked")
        let poll = GitHubStub.seen.first { $0.path == "/login/oauth/access_token" }
        #expect(poll?.body?["grant_type"] as? String == "urn:ietf:params:oauth:grant-type:device_code")
        #expect(poll?.body?["client_id"] as? String == "Iv23test")
        #expect(GitHubStub.seen.last?.auth == "Bearer ghu_abc")
    }

    @Test(arguments: [("access_denied", "You declined"), ("expired_token", "The code expired")])
    func aDeclinedOrExpiredCodeSaysSo(error: String, says: String) async {
        GitHubStub.reset()
        GitHubStub.on("POST /login/device/code", 200, #"{"device_code":"dc1","user_code":"AAAA-BBBB","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#)
        GitHubStub.on("POST /login/oauth/access_token", 200, "{\"error\":\"\(error)\"}")
        let a = auth()
        await a.signIn { _, _ in }
        guard case let .failed(why) = a.state else { Issue.record("expected failed"); return }
        #expect(why.hasPrefix(says), "\(why)")
        #expect(a.token == nil)
    }

    @Test func signOutForgetsTheToken() {
        let keychain = MemoryKeychain()
        keychain.items[GitHubAuth.tokenKey] = "ghu_abc"
        let a = auth(keychain)
        #expect(a.token == "ghu_abc")
        a.signOut()
        #expect(a.token == nil)
        #expect(a.state == .signedOut)
    }

    @Test func noClientIDMeansNoSignIn() {
        let a = GitHubAuth(clientID: "$(MUXBOT_GITHUB_CLIENT_ID)", session: GitHubStub.session, keychain: MemoryKeychain())
        #expect(!a.isConfigured)
    }

    @Test func signedInReadsCarryTheToken() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kstrat2001/hcr/issues", 200, "[]")
        let gh = RESTGitHubClient(session: GitHubStub.session, token: { "ghu_abc" })
        _ = try await gh.openIssues(repo: "kstrat2001/hcr")
        #expect(GitHubStub.seen.last?.auth == "Bearer ghu_abc")
    }

    @Test func theAppSaysWhenItIsntInstalledOnTheRepo() async {
        GitHubStub.reset()
        GitHubStub.on("GET /user/installations", 200, #"{"total_count":1,"installations":[{"id":7,"app_slug":"mux-bot-app","account":{"login":"kstrat2001"}}]}"#)
        GitHubStub.on("GET /user/installations/7/repositories", 200, #"{"total_count":1,"repositories":[{"full_name":"kstrat2001/darkmux"}]}"#)
        let keychain = MemoryKeychain(); keychain.items[GitHubAuth.tokenKey] = "ghu_abc"
        let a = auth(keychain)
        let state = await a.installState(for: "kstrat2001/hcr")
        #expect(state == .notInstalled(URL(string: "https://github.com/apps/mux-bot-app/installations/new")!))
        GitHubStub.on("GET /user/installations", 200, #"{"total_count":1,"installations":[{"id":7,"app_slug":"mux-bot-app","account":{"login":"kstrat2001"}}]}"#)
        GitHubStub.on("GET /user/installations/7/repositories", 200, #"{"total_count":1,"repositories":[{"full_name":"kstrat2001/hcr"}]}"#)
        #expect(await a.installState(for: "kstrat2001/hcr") == .installed)
    }
}
