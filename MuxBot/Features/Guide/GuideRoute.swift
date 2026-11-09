import Foundation

/// Mux Bot, the lead bot, as a guide: the setup check, the first bot, help
/// from the bundled articles, and settings with their live switch. The
/// whole feature hangs off this flag and one call in `BotBrain.respond`, so
/// it can be cut by turning it off.
enum Guide {
    static let isEnabled = true
}

/// What a message in Mux Bot's thread asks the guide for. nil leaves it to
/// the lead bot as before (hand-offs, new bots by name, work status).
enum GuideRoute: Equatable, Sendable {
    case setup
    case firstBot(resource: String?)
    case setting(GuideSettingID)
    /// "Change a setting": the settings he can show switches for.
    case settingsOverview
    case help

    private static let setupPhrases = [
        "check my setup", "check setup", "setup check", "check the setup", "get started", "getting started",
        "set me up", "help me set up", "set up mux bot", "set up darkmux", "everything ready", "am i ready",
        "what do i need to set up", "what do i need to get started", "onboard",
    ]
    private static let firstBotPhrases = [
        "first bot", "point me at a repo", "bot for my repo", "bot from a repo", "bot from my repo", "bot for this repo",
        "make a bot for", "create a bot for", "add a bot for", "set up a bot for", "bot for my project",
    ]
    private static let questionStarts = [
        "how", "what", "why", "where", "when", "can", "could", "does", "do", "is", "are", "which", "who", "should", "will", "explain", "tell me about",
    ]

    static func route(_ text: String) -> GuideRoute? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty, Intent.issueNumber(in: text) == nil, !WorkStatus.isWorkQuestion(lower),
              Intent.parse(text).0 == nil else { return nil }
        if setupPhrases.contains(where: lower.contains) { return .setup }
        // A path in a question ("What does /client/profiles do?") is
        // something to explain, not a folder to make a bot for.
        let resource = repoLink(in: text) ?? (isQuestion(lower) ? nil : folderPath(in: text))
        if resource != nil || firstBotPhrases.contains(where: lower.contains) {
            return .firstBot(resource: resource)
        }
        if let setting = GuideSettings.match(lower) { return .setting(setting) }
        if ["change a setting", "change settings", "my settings", "which settings", "what settings", "show settings", "open settings"]
            .contains(where: lower.contains) || lower == "settings" {
            return .settingsOverview
        }
        if isQuestion(lower) { return .help }
        return nil
    }

    static func isQuestion(_ lower: String) -> Bool {
        lower.hasSuffix("?") || questionStarts.contains { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + "'") }
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[],.;:?!\"'")) }
    }

    /// A GitHub repo link in the message.
    static func repoLink(in text: String) -> String? {
        words(text).first { GitHubIssue.repoSlug(from: $0) != nil && $0.contains("github.com") }
    }

    /// A path that looks like a folder on this Mac (under /Users or ~), not
    /// an endpoint like /client/profiles.
    static func folderPath(in text: String) -> String? {
        words(text).first { ($0.hasPrefix("/Users/") || $0.hasPrefix("~/")) && $0.count > 2 }
    }
}
