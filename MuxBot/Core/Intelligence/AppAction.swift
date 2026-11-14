import Foundation

/// Things the app itself does when you ask in a bot's thread ("open the
/// preview", "reload the preview"): matched by rules before any crew work,
/// so asking for the app never becomes a coding run. One registry; each
/// entry names its own words and nothing else may be in the message.
enum AppAction: String, CaseIterable, Sendable {
    case openPreview
    case hidePreview
    case reloadPreview

    /// How a matched action is carried out.
    enum Handling: Sendable {
        /// Only opens or shows something: done at once, with one line.
        case direct
        /// Changes something: an Approve card first.
        case card
    }

    var handling: Handling {
        switch self {
        case .openPreview, .hidePreview, .reloadPreview: .direct
        }
    }

    /// One of these must be in the message: what the action is about.
    private var objects: Set<String> {
        switch self {
        case .openPreview, .hidePreview, .reloadPreview: ["preview", "previews"]
        }
    }

    /// The words that pick this action over the others with the same object.
    /// An action with no verb words matches on its object and filler alone.
    private var verbs: Set<String> {
        switch self {
        // "restart" opens it for now; restarting the server is its own action later.
        case .openPreview: ["start", "open", "show", "run", "launch", "see", "view", "display", "turn", "on", "bring", "up",
                            "restart", "load", "get", "go", "toggle", "where", "happened"]
        case .hidePreview: ["hide", "close", "dismiss", "collapse", "away"]
        case .reloadPreview: ["reload", "refresh"]
        }
    }

    /// Words any action's message may hold besides its own.
    private static let filler: Set<String> = [
        "is", "s", "whats", "what", "to", "the", "a", "my", "me", "our", "this", "that", "it", "its", "again", "now",
        "please", "pls", "can", "could", "would", "will", "you", "i", "want", "let", "lets", "us", "need",
        "live", "site", "website", "page", "app", "button",
    ]

    /// Longer messages are about something else ("preview the new pricing
    /// page for phones and tablets with the menu open").
    private static let maxWords = 8

    /// The one action the message asks for, or nil (more than one, or
    /// words none of them uses, such as "show the price on the preview").
    static func match(_ text: String) -> AppAction? {
        let words = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter }
            .map(String.init)
        guard !words.isEmpty, words.count <= maxWords else { return nil }
        let found = allCases.filter { $0.accepts(words) }
        return found.count == 1 ? found[0] : nil
    }

    private func accepts(_ words: [String]) -> Bool {
        guard words.contains(where: objects.contains) else { return false }
        let content = words.filter { !objects.contains($0) && !Self.filler.contains($0) }
        // Only this action's words; "the preview?" alone asks to see it.
        guard content.allSatisfy(verbs.contains) else { return false }
        return !content.isEmpty || isDefault
    }

    /// What the object alone asks for ("preview?").
    private var isDefault: Bool { self == .openPreview }

    /// Whether the bot can do it now; nil when it can, else the sentence
    /// that says why not (never handed to the crew instead).
    @MainActor
    func unavailable(for bot: Bot, runs: RunCoordinator) -> String? {
        switch self {
        case .openPreview, .reloadPreview: runs.canPreview(bot) ? nil : PreviewRequest.cantText(bot.name)
        case .hidePreview: nil
        }
    }

    /// What the bot says as it does it.
    var doingText: String {
        switch self {
        case .openPreview: PreviewRequest.openingText
        case .hidePreview: String(localized: "Hiding the preview.")
        case .reloadPreview: String(localized: "Reloading the preview.")
        }
    }
}

/// A bot's thread asked the app for something; the thread on screen does it.
struct AppActionRequest: Equatable, Sendable {
    var bot: UUID
    var action: AppAction
}
