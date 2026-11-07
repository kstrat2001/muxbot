import Foundation

/// Turns a GitHub issue into a compact brief a local coding model can act
/// on: the page, the element, what's measured, what's expected, the likely
/// file and when it's done. Never just a title.
enum IssueBrief {
    struct Parts: Equatable {
        var problem: String?
        var page: String?
        var viewport: Int?
        var selector: String?
        var expected: String?
        var facts: [String] = []
    }

    /// Reads Mux Bot's own bug drafts closely, and plain issues as well as
    /// it can (a /path and a `selector` anywhere in the text).
    static func parse(_ body: String) -> Parts {
        var parts = Parts()
        let sections = sections(of: body)
        parts.problem = sections["what's wrong"]?.firstLine
        parts.expected = sections["expected"]?.firstLine.flatMap { $0.hasPrefix("_") ? nil : $0 }
        parts.facts = (sections.first { $0.key.hasPrefix("page facts") }?.value ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
        if let m = body.range(of: #"(?<![\w/])/[a-z0-9][a-z0-9/_-]*"#, options: .regularExpression) {
            parts.page = String(body[m])
        } else if body.range(of: #"Open / "#, options: .regularExpression) != nil {
            parts.page = "/"
        }
        if let m = body.range(of: #"at (\d+)px wide"#, options: .regularExpression) {
            parts.viewport = Int(body[m].filter(\.isNumber))
        }
        if let m = body.range(of: #"Look at `[^`]+`"#, options: .regularExpression) {
            parts.selector = String(body[m].dropFirst("Look at `".count).dropLast())
        } else if let m = body.range(of: #"`[^`]*[.#>][^`]*`"#, options: .regularExpression) {
            parts.selector = String(body[m].dropFirst().dropLast())
        }
        return parts
    }

    /// The page's source file, from the repo's own `page_file` pattern in
    /// its preview recipe; nil when the repo doesn't say (no guessing).
    static func likelyFile(forPage page: String?, pattern: String?) -> String? {
        guard let page, let pattern, pattern.contains("{page}") else { return nil }
        let name = page.split(separator: "?").first.flatMap { $0.split(separator: "/").last }.map(String.init) ?? ""
        return pattern.replacingOccurrences(of: "{page}", with: name.isEmpty ? "home" : name)
    }

    /// The brief, or nil when the issue says neither where nor what: then
    /// the bot asks first instead of sending a model to search blind.
    static func compose(issue: GitHubIssue, repo: String, crew: CrewRole, pageFile: String? = nil) -> String? {
        let parts = parse(issue.body ?? "")
        guard parts.page != nil || parts.selector != nil else { return nil }
        let verb = crew == .coder ? "Fix" : "Review the code for"
        var lines = ["\(verb) GitHub issue #\(issue.number) in \(repo): \(issue.title)."]
        if let problem = parts.problem { lines.append("Problem: \(problem)") }
        if let page = parts.page { lines.append("Page: \(page)\(parts.viewport.map { " (at \($0)px wide)" } ?? "")") }
        if let selector = parts.selector { lines.append("Element: \(selector)") }
        for fact in parts.facts.prefix(3) { lines.append("Measured: \(String(fact.prefix(220)))") }
        if let file = likelyFile(forPage: parts.page, pattern: pageFile) { lines.append("Likely file: \(file) (check it first)") }
        lines.append("Expected: \(parts.expected ?? "the problem above no longer happens")")
        lines.append("Done when: the expected result holds on that page, with no other visual change.")
        return lines.joined(separator: "\n")
    }

    private static func sections(of body: String) -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("**"), let end = t.dropFirst(2).range(of: "**") {
                current = t.dropFirst(2)[..<end.lowerBound].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                result[current!] = String(t.dropFirst(2)[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let current {
                result[current, default: ""] += (result[current]!.isEmpty ? "" : "\n") + t
            }
        }
        return result
    }
}

private extension String {
    var firstLine: String? {
        split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
