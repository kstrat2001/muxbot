import Foundation

/// An issue or pull request a message mentions: "hcr#9".
struct GitHubRef: Hashable, Sendable {
    var repo: String
    var number: Int
    var url: URL

    var label: String { "\(repo.split(separator: "/").last.map(String.init) ?? repo)#\(number)" }
}

/// Makes chat text tappable. URLs become links (GitHub ones get short labels,
/// "hcr#9", "hcr@f34727f"); with the bot's repo known, "#8", "PR 9",
/// "issue 8", "hcr#9", commit SHAs in context and, in run results, file paths
/// link to GitHub. "owner/repo#N" links anywhere. Inside ``` code blocks only
/// whole URLs link, with their text unchanged. GitHub sends an issue number
/// that is a PR on to the PR, so numbers always link to /issues/N.
enum Linkify {
    static func attributed(_ text: String, repo: String?, ref: String? = nil, linkPaths: Bool = false) -> AttributedString {
        apply(to: AttributedString(text), repo: repo, ref: ref, linkPaths: linkPaths)
    }

    /// Links an already-styled string (parsed markdown), keeping its styling.
    static func apply(to input: AttributedString, repo: String?, ref: String? = nil, linkPaths: Bool = false) -> AttributedString {
        var result = input
        let text = String(input.characters)
        // Back to front, so earlier ranges stay valid when a label replaces a URL.
        for match in matches(in: text, repo: repo, ref: ref ?? "HEAD", linkPaths: linkPaths).reversed() {
            guard let r = Range(match.range, in: result) else { continue }
            if let label = match.label {
                var replacement = AttributedString(label, attributes: result[r].runs.first?.attributes ?? AttributeContainer())
                replacement.link = match.url
                result.replaceSubrange(r, with: replacement)
            } else {
                result[r].link = match.url
            }
        }
        return result
    }

    /// The issues and pull requests a text mentions, first mention first, for
    /// the link chips on cards.
    static func references(in text: String, repo: String?) -> [GitHubRef] {
        var seen = Set<String>()
        return matches(in: text, repo: repo, ref: "HEAD", linkPaths: false).compactMap { $0.ref }
            .filter { seen.insert("\($0.repo)#\($0.number)").inserted }
    }

    // MARK: - Matching

    struct Match {
        var range: Range<String.Index>
        var url: URL
        var label: String?
        var ref: GitHubRef?
    }

    static func matches(in text: String, repo: String?, ref: String, linkPaths: Bool) -> [Match] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let code = codeBlocks(in: text)
        func inCode(_ r: Range<String.Index>) -> Bool { code.contains { $0.overlaps(r) } }

        var found: [Match] = []
        func add(_ m: Match) {
            guard !found.contains(where: { $0.range.overlaps(m.range) }) else { return }
            found.append(m)
        }
        func each(_ pattern: String, _ body: (NSTextCheckingResult, Range<String.Index>) -> Void) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            for m in re.matches(in: text, range: all) {
                guard let r = Range(m.range, in: text), !inCode(r) else { continue }
                body(m, r)
            }
        }
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
        }
        func issueRef(_ repo: String, _ number: String) -> GitHubRef? {
            guard let n = Int(number), let url = URL(string: "https://github.com/\(repo)/issues/\(n)") else { return nil }
            return GitHubRef(repo: repo, number: n, url: url)
        }

        // 1. URLs (also inside code, where they keep their text).
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: text, range: all) {
                guard let url = m.url, let r = Range(m.range, in: text) else { continue }
                let short = inCode(r) ? nil : shortGitHub(url)
                add(Match(range: r, url: url, label: short?.label, ref: short?.ref))
            }
        }
        // 2. owner/repo#N, anywhere.
        each(#"(?<![\w/.-])([A-Za-z0-9][\w.-]*/[\w.-]+)#(\d{1,6})\b"#) { m, r in
            if let gr = issueRef(group(m, 1)!, group(m, 2)!) { add(Match(range: r, url: gr.url, ref: gr)) }
        }
        guard let repo else { return found.sorted { $0.range.lowerBound < $1.range.lowerBound } }
        let name = String(repo.split(separator: "/").last ?? "")

        // 3. "hcr#9", the short label.
        each(#"(?<![\w/.-])([\w.-]+)#(\d{1,6})\b"#) { m, r in
            guard group(m, 1)?.caseInsensitiveCompare(name) == .orderedSame, let gr = issueRef(repo, group(m, 2)!) else { return }
            add(Match(range: r, url: gr.url, ref: gr))
        }
        // 4. "PR 9", "issue #8", "pull request 10".
        each(#"(?i)\b(?:PR|pull request|issue)\s+#?(\d{1,6})\b"#) { m, r in
            if let gr = issueRef(repo, group(m, 1)!) { add(Match(range: r, url: gr.url, ref: gr)) }
        }
        // 5. "#8" on its own: not a color (#ff0000), not a fragment (page#top).
        each(#"(?<![\w/#&])#(\d{1,6})\b(?![\w-])"#) { m, r in
            if let gr = issueRef(repo, group(m, 1)!) { add(Match(range: r, url: gr.url, ref: gr)) }
        }
        // 6. Commit SHAs, after "commit"/"sha", in backticks, or full length.
        each(#"(?i)(?:\b(?:commit|sha)[:\s]+`?|`)([0-9a-f]{7,40})\b|\b([0-9a-f]{40})\b"#) { m, _ in
            let i = m.range(at: 1).location != NSNotFound ? 1 : 2
            guard let sha = group(m, i), sha.contains(where: \.isNumber), sha.contains(where: \.isLetter),
                  let r = Range(m.range(at: i), in: text),
                  let url = URL(string: "https://github.com/\(repo)/commit/\(sha)") else { return }
            add(Match(range: r, url: url))
        }
        // 7. File paths in run results.
        if linkPaths {
            each(#"(?<![\w/.:@-])((?:[\w.-]+/)+[\w.-]+\.[A-Za-z0-9]{1,6})\b"#) { m, r in
                guard let path = group(m, 1),
                      let url = URL(string: "https://github.com/\(repo)/blob/\(ref)/\(path)") else { return }
                add(Match(range: r, url: url))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// "hcr#9" for an issue or PR URL, "hcr@f34727f" for a commit; nil for
    /// any other URL.
    static func shortGitHub(_ url: URL) -> (label: String, ref: GitHubRef?)? {
        guard url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4 else { return nil }
        let repo = "\(parts[0])/\(parts[1])"
        switch parts[2] {
        case "issues", "pull":
            guard let n = Int(parts[3]) else { return nil }
            let ref = GitHubRef(repo: repo, number: n, url: url)
            return (ref.label, ref)
        case "commit":
            return ("\(parts[1])@\(parts[3].prefix(7))", nil)
        default:
            return nil
        }
    }

    /// The ranges of ``` fenced blocks, fences included; an unclosed fence
    /// runs to the end.
    static func codeBlocks(in text: String) -> [Range<String.Index>] {
        var blocks: [Range<String.Index>] = []
        var cursor = text.startIndex
        while let open = text.range(of: "```", range: cursor..<text.endIndex) {
            let close = text.range(of: "```", range: open.upperBound..<text.endIndex)
            let end = close?.upperBound ?? text.endIndex
            blocks.append(open.lowerBound..<end)
            cursor = end
            if close == nil { break }
        }
        return blocks
    }
}
