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
    /// Start a project: the Start chooser, or a template's form when the
    /// message names one from the registry ("write a book").
    case startProject(template: String?)

    private static let setupPhrases = [
        "check my setup", "check setup", "setup check", "check the setup", "get started", "getting started",
        "set me up", "help me set up", "set up mux bot", "set up darkmux", "everything ready", "am i ready",
        "what do i need to set up", "what do i need to get started", "onboard",
    ]
    private static let firstBotPhrases = [
        "first bot", "point me at a repo", "bot for my repo", "bot from a repo", "bot from my repo", "bot for this repo",
        "make a bot for", "create a bot for", "add a bot for", "set up a bot for", "bot for my project",
    ]
    private static let startPhrases = [
        "new project", "start a project", "start project", "start something", "start a new", "create a project",
        "make a project", "new site", "new website", "make a website", "make a site", "build a site", "build a website",
        "start a website", "start a site", "new book", "write a book", "start a book",
    ]
    /// Words that never name a template on their own.
    private static let notTemplateWords: Set<String> = [
        "a", "an", "the", "my", "new", "build", "write", "make", "start", "create", "project", "something",
        "for", "to", "and", "of", "your", "lets", "let", "s", "me", "i", "want", "please",
    ]
    private static let questionStarts = [
        "how", "what", "why", "where", "when", "can", "could", "does", "do", "is", "are", "which", "who", "should", "will", "explain", "tell me about",
    ]

    static func route(_ text: String) -> GuideRoute? {
        route(text, templates: TemplateRegistry.knownTemplates())
    }

    /// `templates`: the registry's list, whose ids and titles name templates.
    static func route(_ text: String, templates: [TemplateEntry]) -> GuideRoute? {
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
        // "new project", "write a book", or just a template's name; a
        // question about starting one is for the help.
        if !isQuestion(lower) {
            let named = template(in: lower, from: templates)
            if startPhrases.contains(where: lower.contains) { return .startProject(template: named) }
            if let named, words(lower).count <= 3 { return .startProject(template: named) }
        }
        if let setting = GuideSettings.match(lower) { return .setting(setting) }
        if ["change a setting", "change settings", "my settings", "which settings", "what settings", "show settings", "open settings"]
            .contains(where: lower.contains) || lower == "settings" {
            return .settingsOverview
        }
        if isQuestion(lower) { return .help }
        return nil
    }

    /// The registry template a message names, by its id or a word of its
    /// title ("site" for "website", "book" for "Write a book").
    static func template(in lower: String, from templates: [TemplateEntry]) -> String? {
        let said = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !notTemplateWords.contains($0) }
        for entry in templates {
            let names = ([entry.id] + entry.title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
                .map { $0.lowercased() }.filter { !notTemplateWords.contains($0) }
            let match = said.contains { word in
                names.contains { $0 == word || (word.count >= 4 && ($0.hasSuffix(word) || $0.hasPrefix(word))) }
            }
            if match { return entry.id }
        }
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
