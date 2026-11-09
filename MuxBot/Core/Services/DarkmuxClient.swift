import Foundation

/// Talks to darkmux's local client endpoint on this Mac (loopback only):
/// pairing, then real runs for a paired client. Prototype contract, local
/// darkmux build only.
struct DarkmuxClient: Sendable {
    var baseURL = URL(string: "http://127.0.0.1:8767")!
    /// Tests answer here instead of darkmux.
    var session: URLSession = .shared
    /// darkmux answered 401 to a call with this app's token: it no longer
    /// knows this app (the pairing was revoked).
    var onUnauthorized: (@Sendable () -> Void)?

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
        enum CodingKeys: String, CodingKey { case status, error, result, reason, changes, commit, branch, code; case commitError = "commit_error" }
        enum ResultKeys: String, CodingKey { case finalAssistant = "final_assistant" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decode(String.self, forKey: .status)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            code = try? c.decodeIfPresent(String.self, forKey: .code)
            changes = try? c.decodeIfPresent(Changes.self, forKey: .changes)
            commit = try? c.decodeIfPresent(String.self, forKey: .commit)
            branch = try? c.decodeIfPresent(String.self, forKey: .branch)
            commitError = try? c.decodeIfPresent(String.self, forKey: .commitError)
            let result = try? c.nestedContainer(keyedBy: ResultKeys.self, forKey: .result)
            finalAssistant = try result?.decodeIfPresent(String.self, forKey: .finalAssistant)
        }
    }

    struct ClientError: LocalizedError {
        var message: String
        var status: Int = 0
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
        var parts = URLComponents(url: baseURL.appending(path: "/client/recipe"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "workspace", value: workspace)]
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw ClientError(message: "darkmux answered \(status)") }
        return try JSONDecoder().decode(Reply.self, from: data).recipe
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

    /// Starts (or finds) the workspace's preview; darkmux picks the ports.
    func startPreview(token: String, workspace: String) async throws -> Preview {
        let data = try await send("POST", "/client/workspaces/\(workspace)/preview", body: [String: String](),
                                  headers: ["Authorization": "Bearer \(token)"], timeout: 30)
        return try JSONDecoder().decode(Preview.self, from: data)
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
    func profiles(token: String) async throws -> ProfileList {
        // darkmux looks at every local model server (about 1 s at most);
        // room for a slow LM Studio.
        let data = try await send("GET", "/client/profiles", headers: ["Authorization": "Bearer \(token)"], timeout: 15)
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

    private func send(_ method: String, _ path: String, body: (some Encodable)? = Optional<String>.none,
                      headers: [String: String] = [:], timeout: TimeInterval = 5) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, headers["Authorization"] != nil { onUnauthorized?() }
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ClientError(message: detail ?? "darkmux answered \(status)", status: status)
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
