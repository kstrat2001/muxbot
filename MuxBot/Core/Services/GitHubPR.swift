import Foundation

/// Opens a pull request from a bot's branch with your GitHub sign-in:
/// darkmux hands over the branch's changes (`/changes`), and this creates
/// the blobs, a tree on the base commit, a commit and the branch ref through
/// GitHub's Git Data API, then the PR. darkmux never authors PRs.
struct GitHubPR: Sendable {
    struct PR: Equatable, Sendable {
        var number: Int
        var url: URL
        /// Approved files (`extraFiles`) this commit added.
        var added: [String] = []
        /// Approved files left out, and why (never written over).
        var skipped: [String: Skip] = [:]
    }

    enum Skip: Equatable, Sendable {
        /// The bot's own changes already have this path.
        case inChanges
        /// The base branch already has it: it's in the repo now.
        case inBase
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// The Mux Bot GitHub App can't write to this repo (not installed there).
        case cantWrite(String)
        /// Someone else pushed to the PR branch: never overwritten.
        case branchMoved(String)
        /// GitHub doesn't have the commit the work builds on (a 404 on it):
        /// not an install problem.
        case baseMissing(String)
        /// GitHub stopped taking the sign-in and it couldn't be renewed.
        case signInExpired
        /// GitHub refused with no reason of its own.
        case refused(Int)
        case github(String)
        var errorDescription: String? {
            switch self {
            case let .cantWrite(repo): String(localized: "Mux Bot can't write to \(repo) yet: install the Mux Bot GitHub App on it.")
            case let .branchMoved(branch): String(localized: "Someone else pushed to \(branch) on GitHub, so I stopped rather than overwrite it.")
            case let .baseMissing(commit): String(localized: "This work builds on a commit GitHub doesn't have (\(String(commit.prefix(7)))), so I couldn't put it there. Push that commit to GitHub, then try again.")
            case .signInExpired: GitHubAuth.expiredMessage
            case let .refused(status): GitHubPlain.sentence(status: status, signedIn: true)
            case let .github(why): String(localized: "GitHub said: \(why)")
            }
        }
    }

    var session: URLSession = .shared
    private let current: GitHubToken
    var token: String { current.value }
    /// Where this Mac keeps the commit it last wrote to each bot branch.
    var local: LocalBotState = .shared

    init(session: URLSession = .shared, token: String, local: LocalBotState = .shared) {
        self.session = session
        current = GitHubToken(token)
        self.local = local
    }

    /// The next branch name after one someone else pushed to:
    /// "mux/site" → "mux/site-2", "mux/site-2" → "mux/site-3".
    static func nextBranch(_ branch: String) -> String { GitHubRepoMaker.nextName(branch) }

    /// Where a project that started on GitHub begins there: darkmux's own
    /// first commit isn't on GitHub, but its files are the same as this
    /// commit's, so the branch is built on this one, and PRs go to `branch`.
    struct Start: Codable, Equatable, Sendable {
        var commit: String
        var branch: String
        /// The branch on GitHub the bot's work goes to (`mux/<bot>`): the
        /// local project works on its own `main`.
        var head: String
    }

    /// The pushed branch: its new commit and the approved files it holds.
    struct Pushed: Equatable, Sendable {
        var commit: String
        var added: [String] = []
        var skipped: [String: Skip] = [:]
    }

    /// Pushes the bot's branch, then opens a PR from it (or finds the one
    /// already open).
    func open(_ changes: DarkmuxClient.Changes, repo: String, title: String, body: String, bot: UUID,
              extraFiles: [String: Data] = [:], start: Start? = nil) async throws -> PR {
        let pushed = try await push(changes, repo: repo, message: title, bot: bot, extraFiles: extraFiles, start: start)
        let api = "https://api.github.com/repos/\(repo)"
        let added = pushed.added, skipped = pushed.skipped
        struct Pull: Decodable { var number: Int; var html_url: String }
        do {
            let pull: Pull = try await send("POST", "\(api)/pulls", ["title": title, "head": start?.head ?? changes.branch, "base": start?.branch ?? changes.baseBranch, "body": body], repo: repo)
            return PR(number: pull.number, url: URL(string: pull.html_url)!, added: added, skipped: skipped)
        } catch Failure.github(let why) where why.localizedCaseInsensitiveContains("already exists") {
            // The PR is already open for this branch; it now shows the new commit.
            let owner = repo.split(separator: "/").first.map(String.init) ?? ""
            let open: [Pull] = try await send("GET", "\(api)/pulls?head=\(owner):\(start?.head ?? changes.branch)&state=open", nil, repo: repo)
            guard let pull = open.first else { throw Failure.github(why) }
            return PR(number: pull.number, url: URL(string: pull.html_url)!, added: added, skipped: skipped)
        }
    }

    /// Writes the bot's branch on GitHub: the base plus every change (and
    /// the approved files), one commit, moved forward without force. Also
    /// the backup of committed runs, with no PR.
    func push(_ changes: DarkmuxClient.Changes, repo: String, message: String, bot: UUID,
              extraFiles: [String: Data] = [:], start: Start? = nil) async throws -> Pushed {
        let api = "https://api.github.com/repos/\(repo)"
        let baseCommit = start?.commit ?? changes.base
        let head = start?.head ?? changes.branch
        struct SHA: Decodable { var sha: String }
        struct Commit: Decodable { struct Tree: Decodable { var sha: String }; var tree: Tree }

        // The tree is the branch's full current state (the base plus every
        // change), so the new commit may go on top of the branch only where
        // this Mac left it (an earlier PR). Anything else there is someone
        // else's work our tree would drop: stop before writing anything.
        // Never a force push.
        struct Ref: Decodable { struct Object: Decodable { var sha: String }; var object: Object }
        let remote: Ref? = try await sendOptional("GET", "\(api)/git/ref/heads/\(head)", repo: repo)
        if let remote, remote.object.sha != local[bot]?.pushedHeads?[head] {
            throw Failure.branchMoved(head)
        }

        var entries: [[String: Any]] = []
        for file in changes.files {
            if file.deleted == true {
                entries.append(["path": file.path, "mode": "100644", "type": "blob", "sha": NSNull()])
            } else {
                let blob: SHA = try await send("POST", "\(api)/git/blobs", ["content": file.content ?? "", "encoding": "base64"], repo: repo)
                entries.append(["path": file.path, "mode": file.mode ?? "100644", "type": "blob", "sha": blob.sha])
            }
        }
        // Files you approved for the PR (a preview recipe): exactly those
        // bytes, never over the bot's own change or one the base has.
        var added: [String] = []
        var skipped: [String: Skip] = [:]
        for (path, data) in extraFiles.sorted(by: { $0.key < $1.key }) {
            if changes.files.contains(where: { $0.path == path }) { skipped[path] = .inChanges; continue }
            let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            let existing: [String: AnyCodable]? = try await sendOptional("GET", "\(api)/contents/\(encoded)?ref=\(baseCommit)", repo: repo)
            if existing != nil { skipped[path] = .inBase; continue }
            let blob: SHA = try await send("POST", "\(api)/git/blobs", ["content": data.base64EncodedString(), "encoding": "base64"], repo: repo)
            entries.append(["path": path, "mode": "100644", "type": "blob", "sha": blob.sha])
            added.append(path)
        }
        let base: Commit = try await send("GET", "\(api)/git/commits/\(baseCommit)", nil, repo: repo, missing: .baseMissing(baseCommit))
        let tree: SHA = try await send("POST", "\(api)/git/trees", ["base_tree": base.tree.sha, "tree": entries], repo: repo)
        let parent = remote?.object.sha ?? baseCommit
        let commit: SHA = try await send("POST", "\(api)/git/commits", ["message": message, "tree": tree.sha, "parents": [parent]], repo: repo)
        if remote == nil {
            let _: [String: AnyCodable] = try await send("POST", "\(api)/git/refs", ["ref": "refs/heads/\(head)", "sha": commit.sha], repo: repo)
        } else {
            do {
                let _: [String: AnyCodable] = try await send("PATCH", "\(api)/git/refs/heads/\(head)", ["sha": commit.sha, "force": false], repo: repo)
            } catch Failure.github(let why) where why.localizedCaseInsensitiveContains("not a fast forward") {
                // Someone pushed between our look and the move.
                throw Failure.branchMoved(head)
            }
        }
        // Remembered before the PR, which can still fail: the branch is ours
        // at this commit either way.
        local.update(bot) { $0.pushedHeads = ($0.pushedHeads ?? [:]).merging([head: commit.sha]) { $1 } }
        return Pushed(commit: commit.sha, added: added, skipped: skipped)
    }

    /// A GET whose 404 means "not there yet" (nil), not "can't write".
    private func sendOptional<T: Decodable>(_ method: String, _ url: String, repo: String) async throws -> T? {
        let (data, status) = try await load(method, url, nil)
        if status == 404 { return nil }
        guard status == 200 else { throw status == 403 ? Failure.cantWrite(repo) : Failure.refused(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request(_ method: String, _ url: String, _ body: [String: Any]?) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MuxBot", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// One request; a 401 renews the sign-in once and retries with it.
    private func load(_ method: String, _ url: String, _ body: [String: Any]?) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: try request(method, url, body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 401 else { return (data, status) }
        guard let fresh = await GitHubSession.renewed() else { throw Failure.signInExpired }
        current.value = fresh
        let (again, retried) = try await session.data(for: try request(method, url, body))
        let second = (retried as? HTTPURLResponse)?.statusCode ?? 0
        if second == 401 { throw Failure.signInExpired }
        return (again, second)
    }

    /// `missing` is what a 404 means here, when it isn't "can't write".
    private func send<T: Decodable>(_ method: String, _ url: String, _ body: [String: Any]?, repo: String,
                                    missing: Failure? = nil) async throws -> T {
        let (data, status) = try await load(method, url, body)
        guard (200..<300).contains(status) else {
            if status == 404, let missing { throw missing }
            if status == 403 || status == 404 { throw Failure.cantWrite(repo) }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let detail = ((json?["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? (json?["message"] as? String) else {
                throw Failure.refused(status)
            }
            throw Failure.github(detail)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Decodes any JSON value (for replies whose content we don't need).
struct AnyCodable: Decodable {
    init(from decoder: any Decoder) throws {}
}

/// A PR's title and body, from the runs it carries.
enum PRText {
    @MainActor
    static func make(bot: Bot, runs: [BotRun], machine: String) -> (title: String, body: String) {
        let clean = { (task: String) in task.replacingOccurrences(of: #"\s*\([\w.-]+/[\w.-]+\)\s*$"#, with: "", options: .regularExpression) }
        let title = runs.count == 1 ? clean(runs[0].task) : "\(bot.name): \(runs.count) changes"
        var lines = ["## What changed"]
        for run in runs {
            lines.append("- **\(clean(run.task))**: \(run.summary)")
        }
        let issues = runs.flatMap { run -> [Int] in
            guard let m = run.task.range(of: #"^(?i:fix|fixes)\s+#(\d+)"#, options: .regularExpression) else { return [] }
            return Int(run.task[m].filter(\.isNumber)).map { [$0] } ?? []
        }
        if !issues.isEmpty { lines.append(""); lines += issues.map { "Fixes #\($0)" } }
        lines.append("")
        lines.append("Made on \(machine) by darkmux (a local model), through Mux Bot.")
        return (title, lines.joined(separator: "\n"))
    }
}

/// PRs opened from a thread (its "Opened PR" lines).
enum PRLinks {
    @MainActor
    static func latest(in messages: [ChatMessage]) -> URL? {
        messages.filter { $0.kind == .prCard }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { m in m.content.range(of: #"https://github\.com/[^\s]+/pull/\d+"#, options: .regularExpression).map { URL(string: String(m.content[$0])) } ?? nil }
            .last
    }
}
