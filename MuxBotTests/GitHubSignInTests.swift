import Foundation
import Testing
@testable import MuxBot

/// Answers GitHub requests from a queue per "METHOD path" and records
/// what was asked (no network).
final class GitHubStub: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var body: String; var headers: [String: String] = [:] }
    struct Seen { var method: String; var path: String; var query: String?; var body: [String: Any]?; var auth: String?; var accept: String? }
    nonisolated(unsafe) static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) static var seen: [Seen] = []
    /// Runs around a reply for one "METHOD path": it gets the call that
    /// delivers the reply, to do something just before or after it.
    nonisolated(unsafe) static var hooks: [String: (_ deliver: () -> Void) -> Void] = [:]

    static func reset() { replies = [:]; seen = []; hooks = [:] }
    static func on(_ key: String, _ status: Int = 200, _ body: String, headers: [String: String] = [:]) {
        replies[key, default: []].append(Reply(status: status, body: body, headers: headers))
    }

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
        Self.seen.append(Seen(method: method, path: path, query: request.url!.query, body: json,
                              auth: request.value(forHTTPHeaderField: "Authorization"), accept: request.value(forHTTPHeaderField: "Accept")))
        let key = "\(method) \(path)"
        let reply = Self.replies[key]?.isEmpty == false ? Self.replies[key]!.removeFirst() : Reply(status: 404, body: #"{"message":"Not Found"}"#)
        let deliver = {
            let headers = ["Content-Type": "application/json"].merging(reply.headers) { $1 }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if let hook = Self.hooks[key] { hook(deliver) } else { deliver() }
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

    @Test(arguments: [true, false])
    func aClosedPRsMergeCheckCarriesTheSignIn(signedIn: Bool) async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kstrat2001/hcr/issues/9", 200, #"{"number":9,"title":"Restore padding","labels":[],"state":"closed","pull_request":{}}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/pulls/9", 200, #"{"merged_at":"2026-11-01T00:00:00Z"}"#)
        let gh = RESTGitHubClient(session: GitHubStub.session, token: { signedIn ? "ghu_abc" : nil })
        let found = try await gh.issue(repo: "kstrat2001/hcr", number: 9)
        #expect(found?.statusLine.hasSuffix("merged") == true)
        let pull = GitHubStub.seen.first { $0.path == "/repos/kstrat2001/hcr/pulls/9" }
        #expect(pull?.auth == (signedIn ? "Bearer ghu_abc" : nil))
    }

    @Test func aPrivateRepoFileIsReadWithTheSignIn() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kstrat2001/hcr/contents/.darkmux/preview.json", 200, #"{"command":"npm run dev"}"#)
        let gh = RESTGitHubClient(session: GitHubStub.session, token: { "ghu_abc" })
        let data = try await gh.file(repo: "kstrat2001/hcr", path: PreviewManifest.path)
        #expect(data.map { String(decoding: $0, as: UTF8.self) } == #"{"command":"npm run dev"}"#)
        let read = GitHubStub.seen.last
        #expect(read?.path == "/repos/kstrat2001/hcr/contents/.darkmux/preview.json")
        #expect(read?.auth == "Bearer ghu_abc")
        #expect(read?.accept == "application/vnd.github.raw+json", "the file's own bytes, not JSON about it")
    }

    @Test func signedOutAFileIsReadFromRawWithoutAToken() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /kstrat2001/hcr/HEAD/.darkmux/preview.json", 200, #"{"command":"npm run dev"}"#)
        let gh = RESTGitHubClient(session: GitHubStub.session, token: { nil })
        #expect(try await gh.file(repo: "kstrat2001/hcr", path: PreviewManifest.path) != nil)
        #expect(GitHubStub.seen.last?.path == "/kstrat2001/hcr/HEAD/.darkmux/preview.json")
        #expect(GitHubStub.seen.last?.auth == nil)
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

    final class TaskBox: @unchecked Sendable { var task: Task<Void, Never>? }

    private func codeAndToken() {
        GitHubStub.reset()
        GitHubStub.on("POST /login/device/code", 200, #"{"device_code":"dc1","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
        GitHubStub.on("POST /login/oauth/access_token", 200, #"{"access_token":"ghu_abc","token_type":"bearer","scope":""}"#)
    }

    @Test func cancelingAsTheTokenComesBackKeepsNoToken() async {
        codeAndToken()
        let box = TaskBox()
        // The token arrives while the main actor is busy, and Cancel lands
        // before the sign-in resumes to save it.
        GitHubStub.hooks["POST /login/oauth/access_token"] = { deliver in
            let busy = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { busy.wait() }
            deliver()
            Thread.sleep(forTimeInterval: 0.3)
            box.task?.cancel()
            busy.signal()
        }
        let keychain = MemoryKeychain()
        let a = auth(keychain)
        box.task = Task { await a.signIn { _, _ in } }
        await box.task?.value
        #expect(keychain.items[GitHubAuth.tokenKey] == nil, "a canceled sign-in saves no token")
        #expect(a.token == nil)
        #expect(a.state == .signedOut)
    }

    @Test func cancelingWhileItWaitsIsNotAFailure() async {
        codeAndToken()
        let box = TaskBox()
        let keychain = MemoryKeychain()
        // Task.sleep throws CancellationError when the task is canceled.
        let a = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain,
                           sleep: { _ in box.task?.cancel(); throw CancellationError() })
        box.task = Task { await a.signIn { _, _ in } }
        await box.task?.value
        #expect(a.state == .signedOut, "Cancel is not a failed sign-in")
        #expect(keychain.items[GitHubAuth.tokenKey] == nil)
    }

    private func signedIn() -> GitHubAuth {
        let keychain = MemoryKeychain(); keychain.items[GitHubAuth.tokenKey] = "ghu_abc"
        return auth(keychain)
    }

    private func next(_ path: String, page: Int) -> [String: String] {
        ["Link": "<https://api.github.com\(path)?per_page=100&page=\(page)>; rel=\"next\", <https://api.github.com\(path)?per_page=100&page=99>; rel=\"last\""]
    }

    @Test func theInstallCheckReadsEveryPage() async {
        GitHubStub.reset()
        GitHubStub.on("GET /user/installations", 200, #"{"installations":[{"id":7,"app_slug":"mux-bot-app"}]}"#, headers: next("/user/installations", page: 2))
        GitHubStub.on("GET /user/installations", 200, #"{"installations":[{"id":8,"app_slug":"mux-bot-app"}]}"#)
        GitHubStub.on("GET /user/installations/7/repositories", 200, #"{"repositories":[{"full_name":"kstrat2001/darkmux"}]}"#, headers: next("/user/installations/7/repositories", page: 2))
        GitHubStub.on("GET /user/installations/7/repositories", 200, #"{"repositories":[{"full_name":"kstrat2001/other"}]}"#)
        GitHubStub.on("GET /user/installations/8/repositories", 200, #"{"repositories":[{"full_name":"kstrat2001/muxbot"}]}"#, headers: next("/user/installations/8/repositories", page: 2))
        GitHubStub.on("GET /user/installations/8/repositories", 200, #"{"repositories":[{"full_name":"kstrat2001/hcr"}]}"#, headers: next("/user/installations/8/repositories", page: 3))
        let a = signedIn()
        #expect(await a.installState(for: "kstrat2001/hcr") == .installed, "on the second page of the second installation")
        let asked = GitHubStub.seen.map { "\($0.path)?\($0.query ?? "")" }
        #expect(asked.contains("/user/installations?per_page=100&page=2"))
        #expect(asked.contains("/user/installations/8/repositories?per_page=100&page=2"))
        #expect(!asked.contains("/user/installations/8/repositories?per_page=100&page=3"), "stops once it's found")
        #expect(GitHubStub.seen.allSatisfy { $0.auth == "Bearer ghu_abc" })
    }

    @Test func theInstallCheckStopsAtAPageCapAndDoesntGuess() async {
        GitHubStub.reset()
        GitHubStub.on("GET /user/installations", 200, #"{"installations":[{"id":7,"app_slug":"mux-bot-app"}]}"#)
        for page in 1...(GitHubAuth.installPageCap + 2) {
            GitHubStub.on("GET /user/installations/7/repositories", 200, "{\"repositories\":[{\"full_name\":\"kstrat2001/r\(page)\"}]}",
                          headers: next("/user/installations/7/repositories", page: page + 1))
        }
        let state = await signedIn().installState(for: "kstrat2001/hcr")
        guard case .unknown = state else { Issue.record("expected unknown, not \(state)"); return }
        #expect(GitHubStub.seen.filter { $0.path == "/user/installations/7/repositories" }.count == GitHubAuth.installPageCap)
    }

    @Test func theTokenOnlyFollowsNextPagesOnGitHubsAPI() {
        #expect(GitHubAuth.nextPage(#"<https://api.github.com/user/installations?page=2>; rel="next""#) == "https://api.github.com/user/installations?page=2")
        #expect(GitHubAuth.nextPage(#"<https://example.com/steal?page=2>; rel="next""#) == nil)
        #expect(GitHubAuth.nextPage(#"<http://api.github.com/user/installations?page=2>; rel="next""#) == nil)
        #expect(GitHubAuth.nextPage(#"<https://api.github.com/user/installations?page=1>; rel="prev""#) == nil)
        #expect(GitHubAuth.nextPage(nil) == nil)
    }
}
