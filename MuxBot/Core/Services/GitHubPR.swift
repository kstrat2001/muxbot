import Foundation

/// Opens a pull request from a bot's branch with your GitHub sign-in:
/// darkmux hands over the branch's changes (`/changes`), and this creates
/// the blobs, a tree on the base commit, a commit and the branch ref through
/// GitHub's Git Data API, then the PR. darkmux never authors PRs.
struct GitHubPR: Sendable {
    struct PR: Equatable, Sendable { var number: Int; var url: URL }

    enum Failure: Error, Equatable, LocalizedError {
        /// The Mux Bot GitHub App can't write to this repo (not installed there).
        case cantWrite(String)
        /// Someone else pushed to the PR branch: never overwritten.
        case branchMoved(String)
        case github(String)
        var errorDescription: String? {
            switch self {
            case let .cantWrite(repo): "Mux Bot can't write to \(repo) yet: install the Mux Bot GitHub App on it."
            case let .branchMoved(branch): "Someone else pushed to \(branch) on GitHub, so I stopped rather than overwrite it. Pull their commits into the bot's branch first."
            case let .github(why): "GitHub said: \(why)"
            }
        }
    }

    var session: URLSession = .shared
    let token: String
    /// Where this Mac keeps the commit it last wrote to each bot branch.
    var local: LocalBotState = .shared

    func open(_ changes: DarkmuxClient.Changes, repo: String, title: String, body: String, bot: UUID) async throws -> PR {
        let api = "https://api.github.com/repos/\(repo)"
        struct SHA: Decodable { var sha: String }
        struct Commit: Decodable { struct Tree: Decodable { var sha: String }; var tree: Tree }

        // The tree is the branch's full current state (the base plus every
        // change), so the new commit may go on top of the branch only where
        // this Mac left it (an earlier PR). Anything else there is someone
        // else's work our tree would drop: stop before writing anything.
        // Never a force push.
        struct Ref: Decodable { struct Object: Decodable { var sha: String }; var object: Object }
        let remote: Ref? = try await sendOptional("GET", "\(api)/git/ref/heads/\(changes.branch)", repo: repo)
        if let remote, remote.object.sha != local[bot]?.pushedHeads?[changes.branch] {
            throw Failure.branchMoved(changes.branch)
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
        let base: Commit = try await send("GET", "\(api)/git/commits/\(changes.base)", nil, repo: repo)
        let tree: SHA = try await send("POST", "\(api)/git/trees", ["base_tree": base.tree.sha, "tree": entries], repo: repo)
        let parent = remote?.object.sha ?? changes.base
        let commit: SHA = try await send("POST", "\(api)/git/commits", ["message": title, "tree": tree.sha, "parents": [parent]], repo: repo)
        if remote == nil {
            let _: [String: AnyCodable] = try await send("POST", "\(api)/git/refs", ["ref": "refs/heads/\(changes.branch)", "sha": commit.sha], repo: repo)
        } else {
            do {
                let _: [String: AnyCodable] = try await send("PATCH", "\(api)/git/refs/heads/\(changes.branch)", ["sha": commit.sha, "force": false], repo: repo)
            } catch Failure.github(let why) where why.localizedCaseInsensitiveContains("not a fast forward") {
                // Someone pushed between our look and the move.
                throw Failure.branchMoved(changes.branch)
            }
        }
        // Remembered before the PR, which can still fail: the branch is ours
        // at this commit either way.
        local.update(bot) { $0.pushedHeads = ($0.pushedHeads ?? [:]).merging([changes.branch: commit.sha]) { $1 } }
        struct Pull: Decodable { var number: Int; var html_url: String }
        do {
            let pull: Pull = try await send("POST", "\(api)/pulls", ["title": title, "head": changes.branch, "base": changes.baseBranch, "body": body], repo: repo)
            return PR(number: pull.number, url: URL(string: pull.html_url)!)
        } catch Failure.github(let why) where why.localizedCaseInsensitiveContains("already exists") {
            // The PR is already open for this branch; it now shows the new commit.
            let owner = repo.split(separator: "/").first.map(String.init) ?? ""
            let open: [Pull] = try await send("GET", "\(api)/pulls?head=\(owner):\(changes.branch)&state=open", nil, repo: repo)
            guard let pull = open.first else { throw Failure.github(why) }
            return PR(number: pull.number, url: URL(string: pull.html_url)!)
        }
    }

    /// A GET whose 404 means "not there yet" (nil), not "can't write".
    private func sendOptional<T: Decodable>(_ method: String, _ url: String, repo: String) async throws -> T? {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw status == 403 ? Failure.cantWrite(repo) : Failure.github("status \(status)") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send<T: Decodable>(_ method: String, _ url: String, _ body: [String: Any]?, repo: String) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MuxBot", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 403 || status == 404 { throw Failure.cantWrite(repo) }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = ((json?["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? (json?["message"] as? String) ?? "status \(status)"
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
