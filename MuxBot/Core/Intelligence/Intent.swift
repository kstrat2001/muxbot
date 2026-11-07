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

    /// The best guess when no prefix or choice was given; nil leaves it to
    /// the model.
    static func infer(_ text: String, hasElement: Bool) -> Intent? {
        let lower = text.lowercased()
        if FallbackBrain.isIssueQuestion(lower) { return .issues }
        if FallbackBrain.isVisualReport(lower) { return .bug }
        if hasElement && !lower.hasSuffix("?") && !lower.isEmpty { return .bug }
        if lower.hasSuffix("?") { return .ask }
        return nil
    }
}
