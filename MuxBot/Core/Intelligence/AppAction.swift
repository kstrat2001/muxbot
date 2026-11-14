import Foundation

/// Things the app itself does when you ask in a bot's thread ("open the
/// preview", "reload the preview"): matched by rules before any crew work,
/// so asking for the app never becomes a coding run. One registry; each
/// entry names its own words and nothing else may be in the message.
enum AppAction: String, CaseIterable, Sendable {
    case openPreview
    case hidePreview
    case reloadPreview
    case stopPreview
    case fullWindowPreview
    case phoneView
    case tabletView
    case desktopView
    case pickMode
    case botInfo
    case pairing

    /// How a matched action is carried out.
    enum Handling: Sendable {
        /// Only opens or shows something: done at once, with one line.
        case direct
        /// Changes something: an Approve card first.
        case card
    }

    var handling: Handling {
        switch self {
        case .openPreview, .hidePreview, .reloadPreview, .stopPreview, .fullWindowPreview, .phoneView, .tabletView,
             .desktopView, .pickMode, .botInfo, .pairing: .direct
        }
    }

    /// One of these must be in the message: what the action is about.
    private var objects: Set<String> {
        switch self {
        case .openPreview, .hidePreview, .reloadPreview, .stopPreview, .fullWindowPreview: ["preview", "previews"]
        case .phoneView: ["phone", "phones", "iphone", "mobile"]
        case .tabletView: ["tablet", "tablets", "ipad"]
        case .desktopView: ["desktop", "laptop", "computer"]
        case .pickMode: ["point", "pick", "pointing"]
        case .botInfo: ["info", "information", "details"]
        case .pairing: ["pair", "pairing", "darkmux"]
        }
    }

    /// The words that pick this action over the others with the same object.
    /// An action with no verb words matches on its object and filler alone.
    private var verbs: Set<String> {
        switch self {
        // "restart" opens it for now; restarting the server is its own action later.
        case .openPreview: ["start", "open", "show", "run", "launch", "see", "view", "display", "turn", "on", "bring", "up",
                            "restart", "load", "get", "go", "toggle", "where", "happened", "button"]
        case .hidePreview: ["hide", "close", "dismiss", "collapse", "away"]
        case .reloadPreview: ["reload", "refresh"]
        case .stopPreview: ["stop", "end", "quit", "shut", "down", "off", "kill", "turn"]
        case .fullWindowPreview: ["full", "screen", "window", "fullscreen", "bigger", "expand", "maximize", "make", "larger"]
        // "show it on a phone", "how does the preview look on a tablet?"
        case .phoneView, .tabletView, .desktopView:
            ["show", "view", "see", "switch", "change", "set", "look", "looks", "how", "does", "on", "as", "in", "like", "at",
             "an", "size", "width", "preview", "for", "check", "try"]
        // "let me point at it", "I want to pick something"
        case .pickMode: ["at", "on", "something", "thing", "element", "an", "out", "start", "turn", "mode", "show", "you", "where"]
        case .botInfo: ["show", "open", "see", "view", "bot", "your", "bots", "info", "about"]
        case .pairing: ["pair", "pairing", "with", "connect", "darkmux", "again", "mux", "bot", "on", "mac"]
        }
    }

    /// Words any action's message may hold besides its own.
    private static let filler: Set<String> = [
        "is", "s", "whats", "what", "to", "the", "a", "my", "me", "our", "this", "that", "it", "its", "again", "now",
        "please", "pls", "can", "could", "would", "will", "you", "i", "want", "let", "lets", "us", "need",
        "live", "site", "website", "page", "app",
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

    /// The device size a size action shows.
    var viewport: PreviewViewport? {
        switch self {
        case .phoneView: .phone
        case .tabletView: .tablet
        case .desktopView: .desktop
        default: nil
        }
    }

    /// What the object alone asks for ("preview?").
    private var isDefault: Bool { self == .openPreview }

    /// Whether the bot can do it now; nil when it can, else the sentence
    /// that says why not (never handed to the crew instead).
    @MainActor
    func unavailable(for bot: Bot, runs: RunCoordinator) -> String? {
        switch self {
        case .openPreview, .reloadPreview, .fullWindowPreview, .phoneView, .tabletView, .desktopView, .pickMode:
            runs.canPreview(bot) ? nil : PreviewRequest.cantText(bot.name)
        case .stopPreview: runs.livePreviews[bot.id] == nil ? String(localized: "The preview isn't running.") : nil
        case .hidePreview, .botInfo: nil
        case .pairing:
            #if os(macOS)
            runs.connection?.isPaired == true ? String(localized: "Mux Bot is already paired with darkmux on this Mac.") : nil
            #else
            String(localized: "Pairing with darkmux happens in Mux Bot on your Mac.")
            #endif
        }
    }

    /// What the bot says as it does it.
    var doingText: String {
        switch self {
        case .openPreview: PreviewRequest.openingText
        case .hidePreview: String(localized: "Hiding the preview.")
        case .reloadPreview: String(localized: "Reloading the preview.")
        case .stopPreview: String(localized: "Stopping the preview. Open it again any time.")
        case .fullWindowPreview: String(localized: "Showing the preview in the full window.")
        case .phoneView: String(localized: "Showing the preview at phone size.")
        case .tabletView: String(localized: "Showing the preview at tablet size.")
        case .desktopView: String(localized: "Showing the preview at desktop size.")
        case .pickMode: String(localized: "Point at something in the preview and click it, then tell me about it.")
        case .botInfo: String(localized: "Opening my info.")
        case .pairing: String(localized: "Opening pairing with darkmux.")
        }
    }
}

/// A bot's thread asked the app for something; the thread on screen does it.
struct AppActionRequest: Equatable, Sendable {
    var bot: UUID
    var action: AppAction
}
