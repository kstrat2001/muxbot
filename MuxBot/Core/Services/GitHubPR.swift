import Foundation

/// Opens a pull request from a task's branch with your GitHub sign-in. The
/// branch gets to GitHub through darkmux's own `git push` from the work
/// copy (darkmux #3681); this only opens the PR (darkmux never authors
/// PRs, #1463).
struct GitHubPR: Sendable {
    struct PR: Equatable, Sendable {
        var number: Int
        var url: URL
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// The Mux Bot GitHub App can't write to this repo (not installed there).
        case cantWrite(String)
        /// GitHub stopped taking the sign-in and it couldn't be renewed.
        case signInExpired
        /// GitHub refused with no reason of its own.
        case refused(Int)
        case github(String)
        var errorDescription: String? {
            switch self {
            case let .cantWrite(repo): String(localized: "Mux Bot can't write to \(repo) yet: install the Mux Bot GitHub App on it.")
            case .signInExpired: GitHubAuth.expiredMessage
            case let .refused(status): GitHubPlain.sentence(status: status, signedIn: true)
            case let .github(why): String(localized: "GitHub said: \(why)")
            }
        }
    }

    var session: URLSession = .shared
    private let current: GitHubToken
    var token: String { current.value }

    init(session: URLSession = .shared, token: String) {
        self.session = session
        current = GitHubToken(token)
    }

    /// Opens a PR from `head` into `base` (or finds the one already open
    /// for that branch).
    func open(repo: String, head: String, base: String, title: String, body: String) async throws -> PR {
        let api = "https://api.github.com/repos/\(repo)"
        struct Pull: Decodable { var number: Int; var html_url: String }
        do {
            let pull: Pull = try await send("POST", "\(api)/pulls", ["title": title, "head": head, "base": base, "body": body], repo: repo)
            return PR(number: pull.number, url: URL(string: pull.html_url)!)
        } catch Failure.github(let why) where why.localizedCaseInsensitiveContains("already exists") {
            // The PR is already open for this branch; it now shows the new commits.
            let owner = repo.split(separator: "/").first.map(String.init) ?? ""
            let open: [Pull] = try await send("GET", "\(api)/pulls?head=\(owner):\(head)&state=open", nil, repo: repo)
            guard let pull = open.first else { throw Failure.github(why) }
            return PR(number: pull.number, url: URL(string: pull.html_url)!)
        }
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
        let fresh: String
        switch await GitHubSession.renewed() {
        case let .token(token): fresh = token
        case .expired: throw Failure.signInExpired
        case .unreachable: throw Failure.refused(0)
        }
        current.value = fresh
        let (again, retried) = try await session.data(for: try request(method, url, body))
        let second = (retried as? HTTPURLResponse)?.statusCode ?? 0
        if second == 401 { throw Failure.signInExpired }
        return (again, second)
    }

    private func send<T: Decodable>(_ method: String, _ url: String, _ body: [String: Any]?, repo: String) async throws -> T {
        let (data, status) = try await load(method, url, body)
        guard (200..<300).contains(status) else {
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
