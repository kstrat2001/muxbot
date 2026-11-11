import Foundation

/// A bot's task and its review (step one of tasks: one automatic task per
/// bot). The task holds every saved change since the last merge; Start
/// review opens its pull request, and then either the Reviewer crew checks
/// it once or you review it yourself. Merge happens in the app when GitHub
/// says it can. People see "task", "review" and "merge", never the git words.
enum TaskReview {
    /// The open review of a bot's task, kept on this Mac (`LocalBotState`).
    struct State: Codable, Equatable, Sendable {
        var number: Int
        var url: URL
        var title: String
        /// You chose to review it yourself: no Reviewer run.
        var mine: Bool = false
        /// The Reviewer's run (its dispatch card), by run id.
        var reviewerRun: String?
        /// The Reviewer's list, once it finished (empty: nothing to change).
        var items: [String]?
        /// The Reviewer's answer when it isn't a numbered list.
        var raw: String?
    }

    // MARK: The Reviewer's brief and answer

    /// What the Reviewer is told to answer when it finds nothing.
    static let nothingLine = "Nothing to change."

    /// The Reviewer's brief: what was asked, what changed, and the exact
    /// shape of the answer, a numbered list the app splits into items.
    static func brief(title: String, tasks: [String], files: [String], diff: String?) -> String {
        var lines = ["Review the changes in this task before they join the project: \u{201C}\(title)\u{201D}.", "", "What was asked:"]
        lines += tasks.map { "- \($0)" }
        lines += ["", "Files changed, compared with the project's main version:"]
        lines += files.map { "- \($0)" }
        if let diff, !diff.isEmpty {
            lines += ["", "The changes:", "```diff", diff, "```"]
        }
        lines += [
            "",
            "Read the changed files. Look for real problems: something that doesn't work, doesn't match what was asked, breaks the layout on a phone or a wide screen, or was left behind by mistake. Skip matters of taste.",
            "Do not change any files.",
            "",
            "Answer with a numbered list and nothing else, the most important first, one problem per item, in this form:",
            "1. <file>: <what is wrong, and what to change>",
            "If there is nothing to change, answer exactly: \(nothingLine)",
        ]
        return lines.joined(separator: "\n")
    }

    /// The most diff the brief carries; larger ones are left to the
    /// Reviewer to read from the files.
    static let briefDiffLimit = 12_000

    /// The Reviewer's answer: `items` when it is the numbered list asked
    /// for (empty when it found nothing), else the text as it is (`raw`).
    static func parse(_ answer: String) -> (items: [String]?, raw: String?) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, nil) }
        let pattern = #"^\s*(\d{1,2})[.)]\s+(.+)$"#
        var items: [String] = []
        var stray = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let match = trimmed.range(of: pattern, options: .regularExpression) {
                let body = String(trimmed[match]).replacingOccurrences(of: #"^\s*\d{1,2}[.)]\s+"#, with: "", options: .regularExpression)
                items.append(clean(body))
            } else if !items.isEmpty, line.first?.isWhitespace == true || trimmed.hasPrefix("-") {
                // An item's own continuation line.
                items[items.count - 1] += " " + clean(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "- ")))
            } else if items.isEmpty, isNothing(trimmed) {
                return ([], nil)
            } else {
                stray = true
            }
        }
        // A list with a sentence before or after it, or no list: shown as is.
        if items.isEmpty || stray { return (nil, text) }
        return (items, nil)
    }

    private static func isNothing(_ line: String) -> Bool {
        let plain = clean(line).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return plain == "nothing to change" || plain.hasPrefix("nothing to change")
    }

    /// Markdown emphasis and code ticks out of a line.
    private static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The Coder's brief for one item ("Fix this") or for the whole answer
    /// ("Fix these").
    static func fixBrief(_ text: String, all: Bool) -> String {
        (all ? "A review of this task's changes said:" : "A review of this task's changes found this problem:")
            + "\n\(text)\n\nFix " + (all ? "what it found" : "it") + ". Change only what that needs."
    }

    /// A dispatch card's one-line task for an item.
    static func fixTask(_ item: String) -> String {
        let line = item.split(whereSeparator: \.isNewline).first.map(String.init) ?? item
        return "Fix: " + (line.count > 80 ? String(line.prefix(80)) + "…" : line)
    }

    // MARK: Where the pull request stands

    enum Standing: Equatable, Sendable {
        /// GitHub is still working out whether it can be merged.
        case checking
        /// Merge can go in now.
        case ready
        /// A rule wants something first, such as another person's review.
        case needsReview
        /// The project changed in the same places.
        case conflict
        /// The project moved on and its rules want this brought up to date.
        case behind
        /// You can't merge on this project.
        case notAllowed
        case merged(String?)
        case closed

        /// One plain sentence for the card; nil when Merge says it all.
        var sentence: String? {
            switch self {
            case .checking: String(localized: "GitHub is still checking whether this can be merged.")
            case .ready: nil
            case .needsReview: String(localized: "This project needs another person's review, or a check to pass, before it can be merged. See it on GitHub.")
            case .conflict: String(localized: "The project changed in the same places since this task started. Sort it out on GitHub, then come back.")
            case .behind: String(localized: "The project moved on since this task started, and its rules want this brought up to date first. Do that on GitHub, then come back.")
            case .notAllowed: String(localized: "Only someone who can merge on this project can merge it. They can do that on GitHub.")
            case .merged: String(localized: "Merged.")
            case .closed: String(localized: "This review was closed on GitHub without merging. Your changes are still here.")
            }
        }
    }

    /// GitHub's word for a pull request (`mergeable_state`) in plain terms.
    static func standing(state: String, merged: Bool, mergeable: Bool?, mergeableState: String?, mergeSHA: String?, canMerge: Bool) -> Standing {
        if merged { return .merged(mergeSHA) }
        if state == "closed" { return .closed }
        switch mergeableState {
        case "dirty": return .conflict
        case "behind": return .behind
        case "blocked": return canMerge ? .needsReview : .notAllowed
        case "clean", "unstable", "has_hooks":
            guard mergeable != false else { return .conflict }
            return canMerge ? .ready : .notAllowed
        default: return .checking
        }
    }

    /// The task's line when the next one starts after a merge. A project
    /// whose work copy starts again from main says its preview won't show
    /// changes still in review elsewhere.
    static func nextTaskLine(fromMain: Bool) -> String {
        fromMain
            ? String(localized: "Merged. Your next change starts a new task from the project's main version, so the preview won't show changes still in review elsewhere until they're merged.")
            : String(localized: "Merged. Your next change starts a new task.")
    }
}

/// GitHub's side of a review: where its pull request stands, and the merge.
struct GitHubReview: Sendable {
    var session: URLSession = .shared
    var token: String

    struct Pull: Decodable {
        var state: String
        var merged: Bool?
        var mergeable: Bool?
        var mergeable_state: String?
        var merge_commit_sha: String?
    }

    func standing(repo: String, number: Int) async throws -> TaskReview.Standing {
        let pull: Pull = try await get("https://api.github.com/repos/\(repo)/pulls/\(number)")
        struct Repo: Decodable { struct Permissions: Decodable { var admin: Bool?; var maintain: Bool?; var push: Bool? }; var permissions: Permissions? }
        let info: Repo? = try? await get("https://api.github.com/repos/\(repo)")
        let p = info?.permissions
        // Unknown permissions: let GitHub's own answer to Merge decide.
        let canMerge = p.map { ($0.push ?? false) || ($0.maintain ?? false) || ($0.admin ?? false) } ?? true
        return TaskReview.standing(state: pull.state, merged: pull.merged ?? false, mergeable: pull.mergeable,
                                   mergeableState: pull.mergeable_state, mergeSHA: pull.merge_commit_sha, canMerge: canMerge)
    }

    /// Merges with a merge commit, else the way the project allows (squash,
    /// then rebase). Returns the commit main is now at.
    func merge(repo: String, number: Int, title: String) async throws -> String {
        var lastWhy = ""
        for method in ["merge", "squash", "rebase"] {
            let (data, status) = try await load("PUT", "https://api.github.com/repos/\(repo)/pulls/\(number)/merge",
                                                ["merge_method": method, "commit_title": title])
            struct Merged: Decodable { var sha: String? }
            if (200..<300).contains(status) { return (try? JSONDecoder().decode(Merged.self, from: data))?.sha ?? "" }
            let why = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
            lastWhy = why
            // This way of merging isn't allowed here: try the next one.
            if status == 405, why.localizedCaseInsensitiveContains("not allowed") { continue }
            if status == 403 { throw GitHubPR.Failure.cantWrite(repo) }
            throw why.isEmpty ? GitHubPR.Failure.refused(status) : GitHubPR.Failure.github(why)
        }
        throw GitHubPR.Failure.github(lastWhy)
    }

    private func get<T: Decodable>(_ url: String) async throws -> T {
        let (data, status) = try await load("GET", url, nil)
        guard status == 200 else { throw GitHubPR.Failure.refused(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func load(_ method: String, _ url: String, _ body: [String: Any]?) async throws -> (Data, Int) {
        func request(_ token: String) throws -> URLRequest {
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
        let (data, response) = try await session.data(for: try request(token))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 401 else { return (data, status) }
        // A 401 renews the sign-in once, as every GitHub call here does.
        switch await GitHubSession.renewed() {
        case let .token(fresh):
            let (again, retried) = try await session.data(for: try request(fresh))
            let second = (retried as? HTTPURLResponse)?.statusCode ?? 0
            if second == 401 { throw GitHubPR.Failure.signInExpired }
            return (again, second)
        case .expired: throw GitHubPR.Failure.signInExpired
        case .unreachable: throw GitHubPR.Failure.refused(0)
        }
    }
}
