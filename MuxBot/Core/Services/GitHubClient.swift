import Foundation
import OSLog
import Synchronization

/// Counts tool calls in one turn, so the brain can tell a checked answer
/// from a guess.
final class ToolCallCounter: Sendable {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }
    func record() { calls.withLock { $0 += 1 } }
}

#if canImport(FoundationModels)
import FoundationModels
#endif

/// An open issue or pull request on GitHub.
struct GitHubIssue: Sendable, Equatable, Decodable {
    struct Label: Sendable, Equatable, Decodable { var name: String }
    struct PullRequestMarker: Sendable, Equatable, Decodable {
        var mergedAt: String? = nil
        enum CodingKeys: String, CodingKey { case mergedAt = "merged_at" }
    }

    var number: Int
    var title: String
    var labels: [Label] = []
    var pullRequest: PullRequestMarker?
    var body: String?
    /// "open" or "closed"; set when the issue was looked up by number.
    var state: String? = nil

    var isPullRequest: Bool { pullRequest != nil }

    /// Issues a pull request closes: "Fixes #8", "closes owner/repo#4".
    var fixes: [Int] {
        guard isPullRequest, let body else { return [] }
        let re = try? NSRegularExpression(pattern: #"(?i)\b(?:fix(?:es|ed)?|close[sd]?|resolve[sd]?)[:\s]+(?:[\w.-]+/[\w.-]+)?#(\d+)"#)
        let ns = body as NSString
        return (re?.matches(in: body, range: NSRange(location: 0, length: ns.length)) ?? [])
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) }
    }

    /// The line for an issue that open pull requests fix.
    func line(fixedBy prs: [Int]) -> String {
        prs.isEmpty ? line : "\(line) (open PR \(prs.map { "#\($0)" }.joined(separator: ", ")) fixes it)"
    }

    /// "#9 PR: Restore side padding — merged", for a lookup by number.
    var statusLine: String {
        let status = pullRequest?.mergedAt != nil ? "merged" : (state ?? "open")
        return "#\(number) \(isPullRequest ? "PR: " : "")\(title) — \(status)"
    }
    var labelNames: [String] { labels.map(\.name) }

    /// "#12 Fix the footer [bug]" or "#13 PR: Bump deps".
    var line: String {
        let tags = labelNames.isEmpty ? "" : " [\(labelNames.joined(separator: ", "))]"
        return "#\(number) \(isPullRequest ? "PR: " : "")\(title)\(tags)"
    }

    enum CodingKeys: String, CodingKey {
        case number, title, labels, body, state
        case pullRequest = "pull_request"
    }

    /// "owner/repo" from a GitHub URL, or nil if it isn't one.
    static func repoSlug(from url: String) -> String? {
        guard let range = url.range(of: "github.com/") else { return nil }
        let parts = url[range.upperBound...].split(separator: "/").prefix(2)
        guard parts.count == 2 else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : String(parts[1])
        return "\(parts[0])/\(repo)"
    }
}

/// Read-only GitHub access for bots. Behind a protocol so tests can mock it.
protocol GitHubClient: Sendable {
    /// Open issues and pull requests for "owner/repo", newest first.
    func openIssues(repo: String) async throws -> [GitHubIssue]
    /// One issue or pull request by number, open or not; nil if missing.
    func issue(repo: String, number: Int) async throws -> GitHubIssue?
    /// A file on the default branch, or nil if it doesn't exist.
    func file(repo: String, path: String) async throws -> Data?
    /// A pull request's title, state and changed files; nil if there's no
    /// pull request with that number.
    func pullRequest(repo: String, number: Int) async throws -> PullRequestInfo?
}

/// What a pull request was: enough to brief a follow-up run on it.
struct PullRequestInfo: Sendable, Equatable {
    var number: Int
    var title: String
    var merged: Bool
    /// "open" or "closed".
    var state: String
    /// Changed file paths, as GitHub lists them (the first 100).
    var files: [String]

    var status: String { merged ? "merged" : state }
}

/// A repo's darkmux preview recipe, `.darkmux/preview.json`. Draft format.
struct PreviewManifest: Sendable, Equatable, Decodable {
    static let path = ".darkmux/preview.json"

    var command: String
    var port: Int?
    var pages: [String]?
    var viewports: [String]?
    /// A sentence or two on how the repo is laid out, passed to the crew
    /// with every run ("Page components are in inertia/pages/.").
    var conventions: String?
    /// Where a page's source lives, with `{page}` for the route's last
    /// segment ("inertia/pages/{page}.tsx"); `/` is "home".
    var pageFile: String?

    enum CodingKeys: String, CodingKey {
        case command, port, pages, viewports, conventions
        case pageFile = "page_file"
    }

    var summary: String {
        var parts = ["\(command)\(port.map { " on port \($0)" } ?? "")"]
        if let pages, !pages.isEmpty { parts.append("pages \(pages.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}

/// GitHub's REST API: with your sign-in, every read carries the token
/// (private repos, 5,000 requests an hour); without it, public repos only,
/// 60 requests an hour per IP.
struct RESTGitHubClient: GitHubClient {
    var session: URLSession = .shared
    /// Your GitHub sign-in, when there is one (private repos, higher limits).
    var token: @Sendable () async -> String? = { KeychainHelper().get(key: GitHubAuth.tokenKey) }
    /// Responses by URL with their ETag: a 304 reply (unchanged) doesn't
    /// count against the 60-an-hour limit.
    private let cache = ETagCache()

    func openIssues(repo: String) async throws -> [GitHubIssue] {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/issues?state=open&per_page=30") else { return [] }
        let data = try await get(url)
        return try JSONDecoder().decode([GitHubIssue].self, from: data)
    }

    /// GET with If-None-Match; a 304 serves the cached body.
    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MuxBot", forHTTPHeaderField: "User-Agent")
        if let token = await token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let cached = cache[url]
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 304, let body = cached?.body { return body }
        guard http?.statusCode == 200 else { throw GitHubError(status: http?.statusCode ?? 0) }
        if let etag = http?.value(forHTTPHeaderField: "ETag") { cache[url] = (etag, data) }
        return data
    }

    func issue(repo: String, number: Int) async throws -> GitHubIssue? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/issues/\(number)") else { return nil }
        let data: Data
        do {
            data = try await get(url)
        } catch let error as GitHubError where error.status == 404 {
            return nil
        }
        var found = try JSONDecoder().decode(GitHubIssue.self, from: data)
        // The issues endpoint doesn't say whether a PR merged; the pulls one does.
        // Through `get`, so a private repo's PR is read with your sign-in.
        if found.isPullRequest, found.state == "closed",
           let prURL = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)") {
            if let prData = try? await get(prURL),
               let marker = try? JSONDecoder().decode(GitHubIssue.PullRequestMarker.self, from: prData) {
                found.pullRequest = marker
            }
        }
        return found
    }
}

extension RESTGitHubClient {
    /// Raw file from the default branch. Signed in, through the contents
    /// API with your token (private repos); signed out, from
    /// raw.githubusercontent.com, which doesn't count against the API rate
    /// limit.
    func file(repo: String, path: String) async throws -> Data? {
        let request: URLRequest
        if let token = await token() {
            guard let url = URL(string: "https://api.github.com/repos/\(repo)/contents/\(path)") else { return nil }
            var signed = URLRequest(url: url)
            signed.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
            signed.setValue("MuxBot", forHTTPHeaderField: "User-Agent")
            signed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request = signed
        } else {
            guard let url = URL(string: "https://raw.githubusercontent.com/\(repo)/HEAD/\(path)") else { return nil }
            request = URLRequest(url: url)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw GitHubError(status: status) }
        return data
    }
}

extension RESTGitHubClient {
    func pullRequest(repo: String, number: Int) async throws -> PullRequestInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)"),
              let filesURL = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)/files?per_page=100") else { return nil }
        struct Pull: Decodable {
            var title: String
            var state: String
            var mergedAt: String?
            enum CodingKeys: String, CodingKey { case title, state, mergedAt = "merged_at" }
        }
        struct File: Decodable { var filename: String }
        let pull: Pull
        do {
            pull = try JSONDecoder().decode(Pull.self, from: try await get(url))
        } catch let error as GitHubError where error.status == 404 {
            return nil   // no such PR (or it's an issue)
        }
        let files = try JSONDecoder().decode([File].self, from: try await get(filesURL))
        return PullRequestInfo(number: number, title: pull.title, merged: pull.mergedAt != nil,
                               state: pull.state, files: files.map(\.filename))
    }
}

/// ETag-validated GitHub responses, shared by copies of the client.
final class ETagCache: Sendable {
    private let entries = Mutex<[URL: (etag: String, body: Data)]>([:])
    subscript(url: URL) -> (etag: String, body: Data)? {
        get { entries.withLock { $0[url] } }
        set { entries.withLock { $0[url] = newValue } }
    }
}

struct GitHubError: LocalizedError {
    var status: Int
    var errorDescription: String? {
        switch status {
        case 403, 429: "GitHub's rate limit for unsigned-in requests is used up (60 an hour)."
        case 404: "GitHub can't find that repo, or it's private (sign-in isn't supported yet)."
        default: "GitHub answered with status \(status)."
        }
    }
}

enum IssueQuery {
    /// Issues matching a label (case-insensitive); all issues if no label
    /// is asked for or none carry it.
    static func filter(_ issues: [GitHubIssue], label: String?, includePullRequests: Bool) -> [GitHubIssue] {
        let pool = includePullRequests ? issues : issues.filter { !$0.isPullRequest }
        guard let label, !label.isEmpty else { return pool }
        let labeled = pool.filter { $0.labelNames.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
        return labeled.isEmpty ? pool : labeled
    }

    /// Issue number → the open pull requests that fix it.
    static func fixedBy(_ issues: [GitHubIssue]) -> [Int: [Int]] {
        var map: [Int: [Int]] = [:]
        for pr in issues where pr.isPullRequest {
            for n in pr.fixes where !(map[n] ?? []).contains(pr.number) { map[n, default: []].append(pr.number) }
        }
        return map
    }

    /// Tool and fallback lines: issues name their open fix PR, PRs name
    /// what they fix.
    static func lines(_ shown: [GitHubIssue], all: [GitHubIssue]) -> [String] {
        let fixed = fixedBy(all)
        return shown.map { i in
            i.isPullRequest && !i.fixes.isEmpty
                ? "\(i.line) (fixes \(i.fixes.map { "#\($0)" }.joined(separator: ", ")))"
                : i.line(fixedBy: fixed[i.number] ?? [])
        }
    }
}

#if canImport(FoundationModels)
/// A repo and the bot it belongs to.
struct BotRepo: Sendable, Equatable {
    var bot: String
    var repo: String
}

/// Lets the on-device model read bots' repos: open issues and PRs.
struct OpenIssuesTool: Tool {
    let repos: [BotRepo]
    let client: any GitHubClient
    var counter = ToolCallCounter()

    let name = "listOpenIssues"
    let description = "Lists open GitHub issues (and optionally pull requests) in the bots' repos, with the open PR that fixes each issue, or looks up one issue or PR by number (open, closed or merged). Always call it before saying anything about issues, bugs, tickets or pull requests."

    @Generable
    struct Arguments {
        @Guide(description: "A label to filter by, such as bug. Empty for all issues.")
        var label: String
        @Guide(description: "true to include open pull requests")
        var includePullRequests: Bool
        @Guide(description: "An issue or pull request number to look up, such as 9. 0 to list open issues.")
        var number: Int
    }

    func call(arguments: Arguments) async throws -> String {
        counter.record()
        Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "tools")
            .debug("listOpenIssues label=\(arguments.label, privacy: .public) prs=\(arguments.includePullRequests) repos=\(repos.map(\.repo).joined(separator: ","), privacy: .public)")
        var lines: [String] = []
        for ref in repos {
            let header = "\(ref.bot) (\(ref.repo))"
            do {
                if arguments.number > 0 {
                    let found = try await client.issue(repo: ref.repo, number: arguments.number)
                    lines.append("\(header): " + (found?.statusLine ?? "no #\(arguments.number)."))
                    continue
                }
                let all = try await client.openIssues(repo: ref.repo)
                let issues = IssueQuery.filter(all, label: arguments.label, includePullRequests: arguments.includePullRequests)
                // Tight cap: the on-device model's context is small.
                let shown = IssueQuery.lines(Array(issues.prefix(5)), all: all).map { "- " + String($0.prefix(110)) }
                let more = issues.count > 5 ? "\n(\(issues.count - 5) more)" : ""
                lines.append(issues.isEmpty ? "\(header): no open issues." : "\(header):\n" + shown.joined(separator: "\n") + more)
            } catch {
                lines.append("\(header): couldn't read issues (\(error.localizedDescription))")
            }
        }
        return lines.isEmpty ? "No bot has a GitHub repo resource yet." : lines.joined(separator: "\n")
    }
}
#endif
