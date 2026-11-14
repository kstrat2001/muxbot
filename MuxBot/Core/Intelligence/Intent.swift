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
        // "no"/"not"/"nope"/"actually" as a whole first word ("now", "note",
        // "nothing" and "notice" are new requests).
        guard lower.count <= 60, lower.range(of: #"^(no|nope|not|actually)\b"#, options: .regularExpression) != nil,
              lower.range(of: #"^no-"#, options: .regularExpression) == nil else { return nil }
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
                // Whole words: "ask" is not in "task", "fix" not in "prefix".
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
                if let r = lower.range(of: pattern, options: [.regularExpression, .backwards]), best == nil || r.lowerBound > best!.1 { best = (intent, r.lowerBound) }
            }
        }
        guard let found = best?.0 else { return nil }
        // Only when the message is just the correction: "actually, also fix
        // the footer" is a new request.
        let cueWords = Set(cues.flatMap(\.1).flatMap { $0.split(separator: " ").map(String.init) })
        let words = lower.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).map { String($0).replacingOccurrences(of: "’", with: "'") }
        let left = words.dropFirst().filter { !cueWords.contains($0) && !correctionFiller.contains($0) }
        return left.isEmpty ? found : nil
    }

    /// Words a correction is made of besides its cue.
    private static let correctionFiller: Set<String> = [
        "it", "it's", "its", "is", "was", "a", "an", "the", "just", "only", "i", "i'm", "meant", "mean", "wanted", "want",
        "please", "that", "that's", "this", "not", "no", "nope", "actually", "really", "should", "be", "to", "as", "so",
        "ok", "okay", "oh", "sorry", "like", "of", "for", "me", "my", "you", "please", "instead", "rather", "wasn't", "isn't",
    ]

    /// "#8", ".../issues/8", "PR 9" or "pull request 9" → the number.
    static func issueNumber(in text: String) -> Int? {
        if let pr = prReference(in: text) { return pr }
        let patterns = [#"/issues/(\d+)"#, #"#(\d+)\b"#, #"(?i)\bissue\s+(\d+)\b"#, #"(?i)\bfix\s+(\d+)\b"#]
        for pattern in patterns {
            if let match = text.range(of: pattern, options: .regularExpression) {
                let digits = text[match].filter(\.isNumber)
                if let n = Int(digits) { return n }
            }
        }
        return nil
    }

    /// "PR 9 is still not right": a complaint about pull request N, with
    /// what's wrong when the message says (nil when it doesn't).
    struct PRComplaint: Equatable {
        var number: Int
        var whatsWrong: String?
    }

    static func prComplaint(in text: String) -> PRComplaint? {
        guard let match = prReferenceRange(in: text), let number = Int(text[match].filter(\.isNumber)) else { return nil }
        var rest = text
        rest.removeSubrange(match)
        guard let cue = complaintCues.lazy.compactMap({ rest.range(of: $0, options: .caseInsensitive) }).first else { return nil }
        rest.removeSubrange(cue)
        return PRComplaint(number: number, whatsWrong: whatsLeft(rest))
    }

    /// "PR 9", "pr #9", "PR#9", "pull request 9" or a /pull/9 link → 9.
    static func prReference(in text: String) -> Int? {
        prReferenceRange(in: text).flatMap { Int(text[$0].filter(\.isNumber)) }
    }

    private static func prReferenceRange(in text: String) -> Range<String.Index>? {
        [#"/pull/\d+"#, #"(?i)\bpr\s*#?\d+\b"#, #"(?i)\bpull request\s*#?\d+\b"#]
            .lazy.compactMap { text.range(of: $0, options: .regularExpression) }.first
    }

    /// Longest first, so "still not right" wins over "still".
    static let complaintCues = [
        "still not right", "still not working", "still broken", "still wrong", "still off",
        "didn't fix", "did not fix", "doesn't fix", "does not fix", "didn't work", "did not work",
        "not right", "not fixed", "is broken", "broke", "wrong", "still",
    ]

    /// What's left of a complaint once the PR and the cue are gone, or nil
    /// when it's only filler ("is", "it").
    private static func whatsLeft(_ rest: String) -> String? {
        let filler: Set<String> = ["is", "it", "its", "it's", "yet", "still", "really", "and", "but"]
        let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, filler.contains(first.lowercased().trimmingCharacters(in: trim)) || first.trimmingCharacters(in: trim).isEmpty {
            words.removeFirst()
        }
        let left = words.joined(separator: " ").trimmingCharacters(in: trim)
        return left.isEmpty ? nil : left
    }

    /// The best guess when no prefix or choice was given; nil leaves it to
    /// the model.
    static func infer(_ text: String, hasElement: Bool) -> Intent? {
        let lower = text.lowercased()
        if issueNumber(in: text) != nil, lower.contains("fix") { return .fix }
        if FallbackBrain.isIssueQuestion(lower) { return .issues }
        if hasElement { return aboutElement(lower) }
        // "Can you change the header color?" asks for a change, not an answer.
        if isPoliteChangeRequest(lower) { return .fix }
        // "change the green color to white", "the header should be blue": a
        // change you want, even when it names a color or a border. Checked
        // before the visual-report words, or every design change would be
        // measured into a bug card.
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        if !GuideRoute.isQuestion(trimmed), !WorkStatus.isWorkQuestion(trimmed),
           isChangeRequest(trimmed) || isChangeWish(trimmed) { return .fix }
        if FallbackBrain.isVisualReport(lower) { return .bug }
        if lower.hasSuffix("?") { return .ask }
        return nil
    }

    /// About something picked in the preview ("Chat about this"): a change
    /// ("make this bigger", "can you replace…") is work, a question is
    /// answered unless it names a problem ("why is this cut off?"), and any
    /// other remark ("no gutter on the sides") is a problem to measure.
    private static func aboutElement(_ lower: String) -> Intent? {
        let text = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var request = text
        for polite in ["please ", "can you ", "could you ", "would you ", "will you ", "pls "] where request.hasPrefix(polite) {
            request = String(request.dropFirst(polite.count))
        }
        if request.hasPrefix("please ") { request = String(request.dropFirst(7)) }  // "can you please…"
        if startsWithChangeVerb(request) || isChangeWish(text) { return .fix }
        if GuideRoute.isQuestion(text) { return problemWords.contains { text.contains($0) } ? .bug : .ask }
        return .bug
    }

    /// "can/could/would/will you <change verb> …".
    static func isPoliteChangeRequest(_ lower: String) -> Bool {
        let text = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let polite = ["can you ", "could you ", "would you ", "will you "].first(where: text.hasPrefix) else { return false }
        var request = String(text.dropFirst(polite.count))
        if request.hasPrefix("please ") { request = String(request.dropFirst(7)) }
        return startsWithChangeVerb(request)
    }

    /// A message that starts with a change ("make the header bigger"),
    /// politely or not.
    static func isChangeRequest(_ lower: String) -> Bool {
        if isPoliteChangeRequest(lower) { return true }
        let text = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = text.hasPrefix("please ") ? String(text.dropFirst(7)) : text
        return startsWithChangeVerb(request)
    }

    /// "the header should be blue", "I want the footer white", "let's add a
    /// logo": a change said as a wish rather than a command.
    static func isChangeWish(_ lower: String) -> Bool {
        let text = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let openers = ["i want ", "i'd like ", "id like ", "i would like ", "let's ", "lets ", "can we ", "could we ",
                       // A rule for the content: "don't use brand names", "no more stock photos".
                       "don't ", "dont ", "do not ", "never ", "avoid ", "stop ", "no more ", "get rid of ",
                       "i don't want ", "i dont want ", "we don't want ", "we dont want "]
        // "this shouldn't be cut off" and "I don't see the menu" describe a
        // problem: measured, not a rule.
        if problemWords.contains(where: text.contains) || ["don't see", "dont see", "don't know", "dont know", "don't understand", "don't get"].contains(where: text.hasPrefix) { return false }
        if openers.contains(where: text.hasPrefix) { return true }
        if [" should be ", " should have ", " needs to be ", " should look "].contains(where: { " \(text) ".contains($0) }) { return true }
        // "we shouldn't use brand names", "the footer shouldn't say 2024".
        let rules = [" shouldn't ", " shouldnt ", " should not ", " must not ", " mustn't "]
        return !text.hasSuffix("?") && rules.contains { " \(text) ".contains($0) }
    }

    /// Whether the first word is a change verb, allowing one typo in a
    /// longer verb ("chanage the color", "repalce the logo").
    private static func startsWithChangeVerb(_ request: String) -> Bool {
        let verb = request.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        if changeVerbs.contains(verb) { return true }
        guard verb.count >= 5 else { return false }
        return changeVerbs.contains { $0.count >= 5 && isOneEditApart(Array(verb), Array($0)) }
    }

    /// One insertion, deletion, substitution or swap of neighbors apart.
    static func isOneEditApart(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return true }
        if abs(a.count - b.count) > 1 { return false }
        var i = 0
        while i < min(a.count, b.count), a[i] == b[i] { i += 1 }
        if a.count == b.count {
            if a[(i + 1)...] == b[(i + 1)...] { return true }  // substitution
            return i + 1 < a.count && a[i] == b[i + 1] && a[i + 1] == b[i] && a[(i + 2)...] == b[(i + 2)...]  // swap
        }
        return a.count > b.count ? a[(i + 1)...] == b[i...] : a[i...] == b[(i + 1)...]
    }

    /// A message about a picked element that starts with one of these asks
    /// for a change.
    private static let changeVerbs: Set<String> = [
        "make", "change", "replace", "swap", "set", "use", "add", "remove", "delete", "drop", "hide", "show",
        "move", "put", "rename", "rewrite", "reword", "update", "edit", "fix", "turn", "increase", "decrease",
        "shrink", "grow", "enlarge", "center", "align", "bold", "italicize", "underline", "shorten",
        "lengthen", "translate", "link", "unlink", "insert", "wrap", "space", "pad", "tighten", "loosen", "say",
    ]

    /// A question about a picked element that names one of these is a
    /// visual problem, measured into a bug card.
    private static let problemWords = [
        "cut off", "clipped", "overlap", "misaligned", "not aligned", "off-center", "off center", "broken",
        "cramped", "squished", "overflow", "too big", "too small", "too wide", "too narrow", "wrong", "missing",
        "hidden", "doesn't fit", "does not fit", "not showing", "pushed",
    ]
}
