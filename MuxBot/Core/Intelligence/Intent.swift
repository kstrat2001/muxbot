import Foundation

/// What a message is for. Inferred by default; a prefix ("bug: ...") or a
/// tap on the message's intent chip sets it explicitly.
enum Intent: String, Codable, CaseIterable, Sendable {
    case ask, bug, fix, review, issues

    var label: String {
        switch self {
        case .ask: "Question"
        case .bug: "Bug report"
        case .fix: "Fix → Coder"
        case .review: "Review → Reviewer"
        case .issues: "Issues"
        }
    }

    var systemImage: String {
        switch self {
        case .ask: "questionmark.bubble"
        case .bug: "ladybug"
        case .fix: "hammer"
        case .review: "magnifyingglass"
        case .issues: "list.bullet"
        }
    }

    /// "bug: the box has no margin" → (.bug, "the box has no margin").
    static func parse(_ text: String) -> (Intent?, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":"),
              let intent = Intent(rawValue: trimmed[..<colon].lowercased()) else { return (nil, trimmed) }
        return (intent, String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }

    /// "no, it's a question", "not a bug, just asking", "actually, fix it":
    /// the user correcting how the bot read their last message.
    static func correction(in text: String) -> Intent? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.count <= 60, ["no", "not ", "nope", "actually"].contains(where: { lower.hasPrefix($0) }) else { return nil }
        let cues: [(Intent, [String])] = [
            (.ask, ["question", "just asking", "only asking", "ask"]),
            (.bug, ["bug"]),
            (.review, ["review"]),
            (.issues, ["issues", "tickets"]),
            (.fix, ["fix", "change it", "do it"]),
        ]
        // The last cue mentioned wins: "not a bug, a question" → question.
        var best: (Intent, String.Index)?
        for (intent, words) in cues {
            for word in words {
                if let r = lower.range(of: word, options: .backwards), best == nil || r.lowerBound > best!.1 { best = (intent, r.lowerBound) }
            }
        }
        return best?.0
    }

    /// "#8" or ".../issues/8" → 8.
    static func issueNumber(in text: String) -> Int? {
        let patterns = [#"/issues/(\d+)"#, #"#(\d+)\b"#, #"(?i)\bissue\s+(\d+)\b"#, #"(?i)\bfix\s+(\d+)\b"#]
        for pattern in patterns {
            if let match = text.range(of: pattern, options: .regularExpression) {
                let digits = text[match].filter(\.isNumber)
                if let n = Int(digits) { return n }
            }
        }
        return nil
    }

    /// The best guess when no prefix or choice was given; nil leaves it to
    /// the model.
    static func infer(_ text: String, hasElement: Bool) -> Intent? {
        let lower = text.lowercased()
        if issueNumber(in: text) != nil, lower.contains("fix") { return .fix }
        if FallbackBrain.isIssueQuestion(lower) { return .issues }
        if FallbackBrain.isVisualReport(lower) { return .bug }
        if hasElement && !lower.hasSuffix("?") && !lower.isEmpty { return .bug }
        if lower.hasSuffix("?") { return .ask }
        return nil
    }
}
