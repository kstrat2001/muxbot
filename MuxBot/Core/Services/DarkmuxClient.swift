import Foundation

/// Talks to darkmux's local client endpoint on this Mac (loopback only):
/// pairing, then real runs for a paired client. Prototype contract, local
/// darkmux build only.
struct DarkmuxClient: Sendable {
    var baseURL = URL(string: "http://127.0.0.1:8767")!
    /// Tests answer here instead of darkmux. Under tests the default never
    /// reaches the network (`defaultSession`).
    var session: URLSession = DarkmuxClient.defaultSession
    /// darkmux answered 401 to a call with this app's token: it no longer
    /// knows that token (the pairing was revoked). Called with the token
    /// that was refused: a late answer about an old one must never undo a
    /// newer pairing.
    var onUnauthorized: (@Sendable (_ refused: String) -> Void)?

    /// The app's shared session; under tests (`TestIsolation`) one whose
    /// every request fails as "can't connect", so a test that forgot its
    /// stub never reaches a darkmux really running on this Mac.
    static let defaultSession: URLSession = {
        guard TestIsolation.isTesting else { return .shared }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoNetworkProtocol.self]
        return URLSession(configuration: config)
    }()

    struct PairStatus: Decodable, Sendable {
        var status: String
        var clientName: String?
        var token: String?
        enum CodingKeys: String, CodingKey { case status, token; case clientName = "client_name" }
    }

    struct WorkStatus: Decodable, Sendable {
        struct Changes: Decodable, Sendable {
            struct File: Decodable, Sendable { var path: String; var added: Int?; var removed: Int? }
            var files: [File]
            var diff: String?
        }
        var status: String
        var error: String?
        var reason: String?
        var finalAssistant: String?
        var changes: Changes?
        /// The run's commit on the work copy's branch (darkmux commits every
        /// finished run with changes), or why there's none.
        var commit: String?
        var branch: String?
        var commitError: String?
        /// Why it failed, for an app (`busy`, `wont_fit`, …; darkmux #3468).
        var code: String?
        /// Why darkmux couldn't read the run's changes (`changes` is then null).
        var changesError: String?
        /// What a failed or stopped run left behind (darkmux 5.10 commits
        /// it as the run's own commit): the files, with `commit`/`branch`.
        var leftFiles: [String]?
        /// While running: what the run is doing besides its turns
        /// (`starting_model`, `queued`); absent otherwise. Kept as darkmux
        /// spells it: a value this app doesn't know shows nothing.
        var activity: String?
        enum CodingKeys: String, CodingKey { case status, error, result, reason, changes, commit, branch, code, files, activity; case commitError = "commit_error"; case changesError = "changes_error" }
        private struct PathOnly: Decodable { var path: String }
        enum ResultKeys: String, CodingKey { case finalAssistant = "final_assistant" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decode(String.self, forKey: .status)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            code = try? c.decodeIfPresent(String.self, forKey: .code)
            changesError = try? c.decodeIfPresent(String.self, forKey: .changesError)
            changes = try? c.decodeIfPresent(Changes.self, forKey: .changes)
            commit = try? c.decodeIfPresent(String.self, forKey: .commit)
            branch = try? c.decodeIfPresent(String.self, forKey: .branch)
            commitError = try? c.decodeIfPresent(String.self, forKey: .commitError)
            activity = try? c.decodeIfPresent(String.self, forKey: .activity)
            if let names = try? c.decodeIfPresent([String].self, forKey: .files) {
                leftFiles = names
            } else if let files = try? c.decodeIfPresent([PathOnly].self, forKey: .files) {
                leftFiles = files.map(\.path)
            }
            let result = try? c.nestedContainer(keyedBy: ResultKeys.self, forKey: .result)
            finalAssistant = try result?.decodeIfPresent(String.self, forKey: .finalAssistant)
        }
    }

    struct ClientError: LocalizedError {
        var message: String
        var status: Int = 0
        /// darkmux's machine-readable reason (`code`), when it sent one.
        var code: String? = nil
        var errorDescription: String? { message }
    }

    /// darkmux decides what apps may run (a machine setting), so a pairing
    /// asks for nothing beyond itself.
    func requestPairing(deviceName: String, code: String, secret: String) async throws -> String {
        struct Body: Encodable { var device_name: String; var code: String; var pair_secret: String }
        struct Reply: Decodable { var request_id: String }
        let data = try await send("POST", "/client/pair", body: Body(device_name: deviceName, code: code, pair_secret: secret))
        return try JSONDecoder().decode(Reply.self, from: data).request_id
    }

    func pairStatus(requestId: String, secret: String) async throws -> PairStatus {
        let data = try await send("GET", "/client/pair/\(requestId)", headers: ["X-Pair-Secret": secret])
        return try JSONDecoder().decode(PairStatus.self, from: data)
    }

    struct WorkBody: Encodable, Sendable {
        var role: String
        var message: String
        var profile: String?
        /// A darkmux workspace name; darkmux resolves the folder.
        var workspace: String
        /// A Tweak: the run it continues.
        var continues: String? = nil
    }

    /// Starts a run in a workspace. `profile` nil lets darkmux pick it the
    /// way `darkmux dispatch <role>` would; the reply names the profile used.
    func submitWork(token: String, role: String, message: String, profile: String?, workspace: String, continues: String? = nil) async throws -> (workId: String, profile: String?) {
        struct Reply: Decodable { var work_id: String; var profile: String? }
        let data = try await send("POST", "/client/work", body: WorkBody(role: role, message: message, profile: profile, workspace: workspace, continues: continues),
                                  headers: ["Authorization": "Bearer \(token)"])
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return (reply.work_id, reply.profile)
    }

    /// Asks darkmux for a workspace: a worktree of a local checkout
    /// (`sourcePath`, on a new branch from the fetched default branch) or a
    /// clone of a repo (`repoURL`). Exactly one of the two.
    struct WorkspaceBody: Encodable, Sendable {
        var repoURL: String?
        var sourcePath: String?
        var bot: String
        /// A template: a fresh project from `repoURL` at `ref` (no history,
        /// no remote), never an existing workspace.
        var template: Bool? = nil
        var ref: String? = nil
        enum CodingKeys: String, CodingKey { case repoURL = "repo_url", sourcePath = "source_path", bot, template, ref }

        /// darkmux names a workspace `<repo ≤32>-<bot>` within 64
        /// characters: the bot's name is sent cut to 31 (until darkmux #3493).
        static let botNameLimit = 31

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(repoURL, forKey: .repoURL)
            try c.encodeIfPresent(sourcePath, forKey: .sourcePath)
            try c.encode(String(bot.prefix(Self.botNameLimit)), forKey: .bot)
            try c.encodeIfPresent(template, forKey: .template)
            try c.encodeIfPresent(ref, forKey: .ref)
        }
    }

    struct Workspace: Decodable, Sendable, Equatable {
        var workspace: String
        var branch: String?
        var head: String?
        var repo: String?
        var created: Bool?
        var fetchError: String?
        enum CodingKeys: String, CodingKey { case workspace, branch, head, repo, created; case fetchError = "fetch_error" }
    }

    /// A clone or worktree can take a while; the reply comes when it's done.
    func setUpWorkspace(token: String, _ body: WorkspaceBody) async throws -> Workspace {
        let data = try await send("POST", "/client/workspaces", body: body, headers: ["Authorization": "Bearer \(token)"], timeout: 600)
        return try JSONDecoder().decode(Workspace.self, from: data)
    }

    func workspace(token: String, name: String) async throws -> Workspace {
        let data = try await send("GET", "/client/workspaces/\(name)", headers: ["Authorization": "Bearer \(token)"])
        return try JSONDecoder().decode(Workspace.self, from: data)
    }

    /// The preview recipe in a workspace; nil when it has none.
    func recipe(token: String, workspace: String) async throws -> PreviewManifest? {
        struct Reply: Decodable { var recipe: PreviewManifest }
        do {
            let data = try await send("GET", "/client/recipe", headers: ["Authorization": "Bearer \(token)"],
                                      query: [URLQueryItem(name: "workspace", value: workspace)])
            return try JSONDecoder().decode(Reply.self, from: data).recipe
        } catch let error as ClientError where error.status == 404 {
            return nil
        }
    }

    struct Preview: Decodable, Sendable {
        var status: String
        var url: String?
        var error: String?
        var logTail: String?
        enum CodingKeys: String, CodingKey { case status, url, error; case logTail = "log_tail" }

        var live: LivePreview {
            let s: LivePreview.Status = switch status {
            case "ready": .ready
            case "installing": .installing
            case "stopped": .stopped
            case "failed": .failed(error ?? "unknown error")
            default: .starting
            }
            return LivePreview(status: s, url: url.flatMap(URL.init(string:)), log: logTail)
        }
    }

    /// A preview start's body: `{}` for a plain start, `{"clean": true}`
    /// to start over (darkmux #3484: it reinstalls the project's packages
    /// in darkmux's workspace, then starts the preview).
    struct PreviewStart: Encodable, Sendable {
        var clean: Bool
        private enum Key: String, CodingKey { case clean }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            if clean { try container.encode(true, forKey: .clean) }
        }
    }

    /// Starts (or finds) the workspace's preview; darkmux picks the ports.
    /// `clean` starts it over (only where `supportsCleanStart` said yes).
    func startPreview(token: String, workspace: String, clean: Bool = false) async throws -> Preview {
        let data = try await send("POST", "/client/workspaces/\(workspace)/preview", body: PreviewStart(clean: clean),
                                  headers: ["Authorization": "Bearer \(token)"], timeout: clean ? 60 : 30)
        return try JSONDecoder().decode(Preview.self, from: data)
    }

    /// Keeps the recipe you approved for darkmux's clone of a repo with none
    /// (darkmux #3571), beside the clone, never in it.
    func setRecipe(token: String, workspace: String, recipe: Data) async throws {
        struct Body: Encodable { var recipe: ApprovedRecipe }
        let parsed = try JSONDecoder().decode(ApprovedRecipe.self, from: recipe)
        _ = try await send("PUT", "/client/workspaces/\(workspace)/recipe", body: Body(recipe: parsed),
                           headers: ["Authorization": "Bearer \(token)"])
    }

    /// The recipe a setup card writes (`PreviewSetup.recipeData`), in
    /// darkmux's shape; absent keys stay absent.
    struct ApprovedRecipe: Codable, Equatable, Sendable {
        struct Ready: Codable, Equatable, Sendable { var http: String }
        struct Install: Codable, Equatable, Sendable {
            var command: String
            var unlessExists: String?
            enum CodingKeys: String, CodingKey { case command; case unlessExists = "unless_exists" }
        }
        var schemaVersion: String
        var command: String
        var env: [String: String]?
        var ready: Ready?
        var install: Install?
        var envFromSource: [String]?
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", command, env, ready, install
            case envFromSource = "env_from_source"
        }
    }

    /// A workspace name no darkmux has, for the probe.
    static let probeWorkspace = "muxbot-capability-probe"

    /// Whether this darkmux can start a preview over. A darkmux with the
    /// clean restart reads the start's body first and refuses an unknown
    /// key (400); an older one never reads the body and refuses the
    /// unknown workspace (404, or 403 with previews off). Nothing starts
    /// either way.
    func supportsCleanStart(token: String) async -> Bool? {
        do {
            _ = try await send("POST", "/client/workspaces/\(Self.probeWorkspace)/preview", body: ["muxbot_capability_probe": true],
                               headers: ["Authorization": "Bearer \(token)"])
            return nil
        } catch let error as ClientError {
            return Self.supportsCleanStart(probeStatus: error.status)
        } catch {
            return nil
        }
    }

    /// 400: darkmux read the body (it has clean starts); 404: an older one
    /// that never read it. Anything else isn't an answer: nil, asked again.
    static func supportsCleanStart(probeStatus: Int) -> Bool? {
        switch probeStatus {
        case 400: true
        case 404: false
        default: nil
        }
    }

    func previewStatus(token: String, workspace: String) async throws -> Preview {
        let data = try await send("GET", "/client/workspaces/\(workspace)/preview", headers: ["Authorization": "Bearer \(token)"])
        return try JSONDecoder().decode(Preview.self, from: data)
    }

    func stopPreview(token: String, workspace: String) async throws {
        _ = try await send("DELETE", "/client/workspaces/\(workspace)/preview", headers: ["Authorization": "Bearer \(token)"], timeout: 15)
    }

    struct KeepResult: Decodable, Sendable, Equatable {
        var commit: String
        var branch: String
        var files: [String]
    }

    struct DiscardResult: Decodable, Sendable, Equatable {
        var restored: [String]
        var removed: [String]
    }

    /// Commits exactly the files the run changed to its work copy's branch.
    func keepWork(token: String, workId: String, message: String) async throws -> KeepResult {
        struct Body: Encodable { var message: String }
        let data = try await send("POST", "/client/work/\(workId)/keep", body: Body(message: message),
                                  headers: ["Authorization": "Bearer \(token)"], timeout: 60)
        return try JSONDecoder().decode(KeepResult.self, from: data)
    }

    /// What a bot's branch holds that the repo's default branch doesn't
    /// (committed changes only), for opening a PR with your GitHub sign-in.
    struct Changes: Decodable, Sendable, Equatable {
        struct File: Decodable, Sendable, Equatable {
            var path: String
            var mode: String?
            /// Base64 file content; nil when deleted.
            var content: String?
            var deleted: Bool?
        }
        var base: String
        var baseBranch: String
        var head: String
        var branch: String
        var files: [File]
        enum CodingKeys: String, CodingKey { case base, head, branch, files; case baseBranch = "base_branch" }
    }

    func changes(token: String, workspace: String) async throws -> Changes {
        let data = try await send("GET", "/client/workspaces/\(workspace)/changes", headers: ["Authorization": "Bearer \(token)"], timeout: 60)
        return try JSONDecoder().decode(Changes.self, from: data)
    }

    /// A hand edit (darkmux #3533): how many places hold the old text, and,
    /// when exactly one did, the work record darkmux committed it as.
    struct EditResult: Decodable, Sendable, Equatable {
        var matches: Int
        var workId: String?
        var file: String?
        var commit: String?
        var branch: String?
        enum CodingKeys: String, CodingKey { case matches, file, commit, branch; case workId = "work_id" }
    }

    /// Replaces the one place in the workspace's files that holds `old`
    /// (as the page shows it) with `new`, committed like a run.
    func handEdit(token: String, workspace: String, old: String, new: String) async throws -> EditResult {
        let data = try await send("POST", "/client/workspaces/\(workspace)/edit", body: ["old": old, "new": new],
                                  headers: ["Authorization": "Bearer \(token)"], timeout: 60)
        return try JSONDecoder().decode(EditResult.self, from: data)
    }

    struct UndoResult: Decodable, Sendable, Equatable {
        var revert: String
        var files: [String]
    }

    /// Reverts the run's commit (a new commit; history is never rewritten).
    func undoWork(token: String, workId: String) async throws -> UndoResult {
        let data = try await send("POST", "/client/work/\(workId)/undo", body: [String: String](),
                                  headers: ["Authorization": "Bearer \(token)"], timeout: 60)
        return try JSONDecoder().decode(UndoResult.self, from: data)
    }

    /// Puts back every file the run changed and removes files it added.
    func discardWork(token: String, workId: String) async throws -> DiscardResult {
        let data = try await send("POST", "/client/work/\(workId)/discard", body: [String: String](),
                                  headers: ["Authorization": "Bearer \(token)"], timeout: 60)
        return try JSONDecoder().decode(DiscardResult.self, from: data)
    }

    func cancelWork(token: String, workId: String) async throws {
        _ = try await send("POST", "/client/work/\(workId)/cancel", headers: ["Authorization": "Bearer \(token)"])
    }

    /// (darkmux #3574) Stops an engine's own server (one darkmux didn't
    /// start, such as rec's) so darkmux can start the model it manages.
    /// Sent only for a run you approved. 409: it wasn't running.
    func stopOwnServer(token: String, engine: String) async throws {
        _ = try await send("POST", "/client/engines/\(engine)/stop-own-server", headers: ["Authorization": "Bearer \(token)"])
    }

    /// A profile this app may run work on here (`GET /client/profiles`):
    /// what it is and whether its server answers now.
    struct ProfileInfo: Decodable, Sendable, Equatable {
        var name: String
        var description: String?
        var model: String?
        var endpoint: String
        var reachable: Bool
        var loaded: Bool?
        var error: String? = nil
        /// (darkmux #3466) Whether darkmux can make it resident: `resident`,
        /// `startable`, `unavailable`, `external` or `unknown`, with a reason
        /// for the last ones. nil from an older darkmux.
        var availability: Availability? = nil
    }

    struct Availability: Decodable, Sendable, Equatable {
        var state: String
        var reason: String?
        /// (darkmux #3574) A code to branch on, never the wording:
        /// `engine_in_use` while the engine's own server runs.
        var code: String? = nil
    }

    /// The darkmux machine: a stable id (the same from every device that
    /// pairs with it) and its name. An older darkmux doesn't say.
    struct Machine: Decodable, Sendable, Equatable {
        var id: String
        var name: String
    }

    struct ProfileList: Decodable, Sendable {
        var role: String
        var profiles: [ProfileInfo]
        var machine: Machine?
    }

    /// The profiles Coder may run on here, in the owner's grant order. An
    /// older darkmux without the route answers 404: no list.
    /// What this app may run `role` on (darkmux defaults to coder).
    func profiles(token: String, role: String = "coder") async throws -> ProfileList {
        // darkmux looks at every local model server (about 1 s at most);
        // room for a slow LM Studio.
        let data = try await send("GET", "/client/profiles", headers: ["Authorization": "Bearer \(token)"],
                                  query: [URLQueryItem(name: "role", value: role)], timeout: 15)
        return try JSONDecoder().decode(ProfileList.self, from: data)
    }

    /// What this app may run here (`GET /client/whoami`): `profiles` is nil
    /// for any local profile (darkmux's default), else the granted names.
    struct Whoami: Decodable, Sendable, Equatable {
        var profiles: [String]?
        enum CodingKeys: String, CodingKey { case scopes }
        enum ScopeKeys: String, CodingKey { case profiles }
        init(profiles: [String]?) { self.profiles = profiles }
        init(from decoder: any Decoder) throws {
            let scopes = try decoder.container(keyedBy: CodingKeys.self).nestedContainer(keyedBy: ScopeKeys.self, forKey: .scopes)
            profiles = try? scopes.decode([String].self, forKey: .profiles)
        }
    }

    func whoami(token: String) async throws -> Whoami {
        let data = try await send("GET", "/client/whoami", headers: ["Authorization": "Bearer \(token)"])
        return try JSONDecoder().decode(Whoami.self, from: data)
    }

    func workStatus(token: String, workId: String) async throws -> WorkStatus {
        let data = try await send("GET", "/client/work/\(workId)", headers: ["Authorization": "Bearer \(token)"])
        return try JSONDecoder().decode(WorkStatus.self, from: data)
    }

    /// The token in an `Authorization: Bearer <token>` header.
    static func bearerToken(_ header: String?) -> String? {
        guard let header, header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }

    private func send(_ method: String, _ path: String, body: (some Encodable)? = Optional<String>.none,
                      headers: [String: String] = [:], query: [URLQueryItem] = [], timeout: TimeInterval = 5) async throws -> Data {
        // The query goes in as query items: in the path, `?` would be encoded.
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, let refused = Self.bearerToken(headers["Authorization"]) { onUnauthorized?(refused) }
        guard (200..<300).contains(status) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = body?["error"] as? String
            throw ClientError(message: detail ?? "darkmux answered \(status)", status: status, code: body?["code"] as? String)
        }
        return data
    }
}

extension CrewRole {
    /// The darkmux built-in role that does this crew role's work; nil when
    /// there isn't one yet (that crew role can't run yet).
    var darkmuxRole: String? {
        switch self {
        case .coder: "coder"
        case .reviewer: "code-reviewer"
        case .researcher: "analyst"
        case .evalRunner: nil
        }
    }
}

/// Fails every request as "can't connect": the only protocol of
/// `DarkmuxClient.defaultSession` under tests.
final class NoNetworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}
