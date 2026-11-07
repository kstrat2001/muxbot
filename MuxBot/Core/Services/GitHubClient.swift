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
    struct PullRequestMarker: Sendable, Equatable, Decodable {}

    var number: Int
    var title: String
    var labels: [Label] = []
    var pullRequest: PullRequestMarker?

    var isPullRequest: Bool { pullRequest != nil }
    var labelNames: [String] { labels.map(\.name) }

    /// "#12 Fix the footer [bug]" or "#13 PR: Bump deps".
    var line: String {
        let tags = labelNames.isEmpty ? "" : " [\(labelNames.joined(separator: ", "))]"
        return "#\(number) \(isPullRequest ? "PR: " : "")\(title)\(tags)"
    }

    enum CodingKeys: String, CodingKey {
        case number, title, labels
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
    /// A file on the default branch, or nil if it doesn't exist.
    func file(repo: String, path: String) async throws -> Data?
}

/// A repo's darkmux preview recipe, `.darkmux/preview.json`. Draft format.
struct PreviewManifest: Sendable, Equatable, Decodable {
    static let path = ".darkmux/preview.json"

    var command: String
    var port: Int?
    var pages: [String]?

    var summary: String {
        var parts = ["\(command)\(port.map { " on port \($0)" } ?? "")"]
        if let pages, !pages.isEmpty { parts.append("pages \(pages.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}

/// Unauthenticated GitHub REST API: public repos only, 60 requests an hour
/// per IP. A GitHub sign-in comes later.
struct RESTGitHubClient: GitHubClient {
    func openIssues(repo: String) async throws -> [GitHubIssue] {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/issues?state=open&per_page=30") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MuxBot", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw GitHubError(status: http.statusCode)
        }
        return try JSONDecoder().decode([GitHubIssue].self, from: data)
    }
}

extension RESTGitHubClient {
    /// Raw file from the default branch (raw.githubusercontent.com, which
    /// doesn't count against the API rate limit).
    func file(repo: String, path: String) async throws -> Data? {
        guard let url = URL(string: "https://raw.githubusercontent.com/\(repo)/HEAD/\(path)") else { return nil }
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw GitHubError(status: status) }
        return data
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
    let description = "Lists open GitHub issues (and optionally pull requests) in the bots' repos. Always call it before saying anything about issues, bugs, tickets or pull requests."

    @Generable
    struct Arguments {
        @Guide(description: "A label to filter by, such as bug. Empty for all issues.")
        var label: String
        @Guide(description: "true to include open pull requests")
        var includePullRequests: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        counter.record()
        Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "tools")
            .debug("listOpenIssues label=\(arguments.label, privacy: .public) prs=\(arguments.includePullRequests) repos=\(repos.map(\.repo).joined(separator: ","), privacy: .public)")
        var lines: [String] = []
        for ref in repos {
            let header = "\(ref.bot) (\(ref.repo))"
            do {
                let issues = IssueQuery.filter(try await client.openIssues(repo: ref.repo),
                                               label: arguments.label, includePullRequests: arguments.includePullRequests)
                lines.append(issues.isEmpty ? "\(header): no open issues." : "\(header):\n" + issues.prefix(10).map { "- \($0.line)" }.joined(separator: "\n"))
            } catch {
                lines.append("\(header): couldn't read issues (\(error.localizedDescription))")
            }
        }
        return lines.isEmpty ? "No bot has a GitHub repo resource yet." : lines.joined(separator: "\n")
    }
}
#endif
