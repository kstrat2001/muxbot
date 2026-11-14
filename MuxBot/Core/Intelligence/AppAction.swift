import Foundation

/// Things the app itself does when you ask in a bot's thread ("open the
/// preview", "reload the preview"): matched by rules before any crew work,
/// so asking for the app never becomes a coding run. One registry; each
/// entry names its own words and nothing else may be in the message.
enum AppAction: String, CaseIterable, Codable, Sendable {
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
    case startReview
    case undoLast
    case stopRun
    case clearConversation
    case archiveBot
    case deleteBot
    case publish
    case save

    /// How a matched action is carried out.
    enum Handling: Sendable {
        /// Only opens or shows something: done at once, with one line.
        case direct
        /// Changes something: an Approve card first.
        case card
        /// Something the app doesn't do: a plain answer that says so.
        case reply
    }

    var handling: Handling {
        switch self {
        case .openPreview, .hidePreview, .reloadPreview, .stopPreview, .fullWindowPreview, .phoneView, .tabletView,
             .desktopView, .pickMode, .botInfo, .pairing,
             // Its sheet is the approval: the title and who reviews are there.
             .startReview: .direct
        case .undoLast, .stopRun, .clearConversation, .archiveBot: .card
        case .deleteBot, .publish, .save: .reply
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
        case .startReview: ["review"]
        case .undoLast: ["undo", "revert"]
        case .stopRun: ["stop"]
        case .clearConversation: ["chat", "conversation", "thread", "messages", "history"]
        case .archiveBot: ["archive"]
        case .deleteBot: ["bot", "yourself", "project"]
        case .publish: ["publish", "deploy", "online", "internet"]
        case .save: ["save", "saved", "saving"]
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
        // "review my changes", "start a review"; "review the login code" is the Reviewer's.
        case .startReview: ["start", "my", "changes", "change", "work", "open", "ask", "for", "ready", "send", "to", "get"]
        // "undo that", "undo the last change"; "undo the header color" is work.
        case .undoLast: ["last", "change", "changes", "go", "back", "please", "run", "edit"]
        case .stopRun: ["run", "running", "work", "working", "crew", "coder", "job", "now"]
        case .clearConversation: ["clear", "empty", "wipe", "erase", "clean", "delete", "out", "start", "over", "fresh", "our"]
        case .archiveBot: ["you", "yourself", "bot", "project", "away", "put"]
        case .deleteBot: ["delete", "remove", "get", "rid", "of", "permanently", "forever", "erase"]
        case .publish: ["it", "site", "website", "put", "go", "how", "do", "i", "can", "on", "the", "live", "make", "get", "ship"]
        // "save my changes", "is it saved?", "how do I save?"
        case .save: ["my", "changes", "change", "work", "how", "do", "i", "did", "you", "everything", "all", "progress", "file",
                     "files", "are", "they", "was", "got", "remember"]
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
    private var isDefault: Bool { [.openPreview, .startReview, .undoLast, .stopRun, .archiveBot, .publish, .save].contains(self) }

    /// Whether the bot can do it now; nil when it can, else the sentence
    /// that says why not (never handed to the crew instead).
    @MainActor
    func unavailable(for bot: Bot, runs: RunCoordinator, store: BotStore) -> String? {
        #if !os(macOS)
        // Runs, work copies and their changes live on the Mac.
        if [.startReview, .undoLast].contains(self) { return String(localized: "That happens in Mux Bot on your Mac, where \(bot.name)'s changes are.") }
        #endif
        switch self {
        case .startReview:
            if runs.review(for: bot) != nil { return String(localized: "\(bot.name) is already in review. It's pinned at the top of this thread.") }
            if bot.repoSlugs.isEmpty { return String(localized: "A review happens on GitHub, and \(bot.name) isn't there yet. Use Put it on GitHub in my info first.") }
            return runs.unshippedRuns(bot, store: store).isEmpty ? String(localized: "There's nothing new to review yet. Ask me for a change first.") : nil
        case .undoLast: return Self.lastUndoable(bot) == nil ? String(localized: "There's nothing to undo yet.") : nil
        case .stopRun:
            if Self.running(bot) != nil { return nil }
            if (bot.runs ?? []).contains(where: { $0.phase.isActive }) { return String(localized: "Stop it from the Mac it runs on.") }
            return String(localized: "Nothing is running right now.")
        case .archiveBot: return BotStore.archiveBlocker(bot)
        case .clearConversation, .deleteBot, .publish, .save: return nil
        case .openPreview, .reloadPreview, .fullWindowPreview, .phoneView, .tabletView, .desktopView, .pickMode:
            return runs.canPreview(bot) ? nil : PreviewRequest.cantText(bot.name)
        case .stopPreview: return runs.livePreviews[bot.id] == nil ? String(localized: "The preview isn't running.") : nil
        case .hidePreview, .botInfo: return nil
        case .pairing:
            #if os(macOS)
            return runs.connection?.isPaired == true ? String(localized: "Mux Bot is already paired with darkmux on this Mac.") : nil
            #else
            return String(localized: "Pairing with darkmux happens in Mux Bot on your Mac.")
            #endif
        }
    }

    /// The newest run of this Mac's with a change Undo can take back.
    @MainActor
    static func lastUndoable(_ bot: Bot) -> BotRun? {
        guard let last = (bot.runs ?? []).filter({ $0.startedAt != nil }).max(by: { $0.createdAt < $1.createdAt }),
              last.phase == .result, last.keptCommit != nil, last.startedHere else { return nil }
        return last
    }

    /// This Mac's run that's going now.
    @MainActor
    static func running(_ bot: Bot) -> BotRun? {
        (bot.runs ?? []).first { $0.phase.isActive && $0.startedHere }
    }

    /// The run a card action is about, named on its card.
    @MainActor
    func target(for bot: Bot) -> BotRun? {
        switch self {
        case .undoLast: Self.lastUndoable(bot)
        case .stopRun: Self.running(bot)
        default: nil
        }
    }

    /// The card's title and line for a card action.
    func cardTitle(bot: String) -> String {
        switch self {
        case .undoLast: String(localized: "Undo the last change")
        case .stopRun: String(localized: "Stop the run")
        case .clearConversation: String(localized: "Clear this conversation")
        case .archiveBot: String(localized: "Archive \(bot)")
        default: doingText
        }
    }

    func cardDetail(bot: String, task: String?) -> String {
        switch self {
        case .undoLast, .stopRun: task.map { "“\($0)”" } ?? ""
        case .clearConversation: String(localized: "Its messages go; runs stay in Activity, and you can undo this until Mux Bot quits.")
        case .archiveBot: String(localized: "\(bot) leaves the sidebar with everything kept. Restore brings it back from Archived Bots.")
        default: ""
        }
    }

    var systemImage: String {
        switch self {
        case .undoLast: "arrow.uturn.backward"
        case .stopRun: "stop.circle"
        case .clearConversation: "eraser"
        case .archiveBot: "archivebox"
        default: "app"
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
        case .startReview: String(localized: "Opening Start review.")
        case .undoLast: String(localized: "Undo it? Approve and darkmux takes that change back.")
        case .stopRun: String(localized: "Stop it? Approve and darkmux stops the run.")
        case .clearConversation: String(localized: "Clear this conversation? Approve to clear it.")
        case .archiveBot: String(localized: "Archive me? Approve to archive.")
        case .deleteBot: String(localized: "Delete is only in Archived Bots, so nothing is deleted by accident. Say “archive this bot” first, then delete it there.")
        case .save: String(localized: "There's nothing to save: every change is saved as soon as its run finishes, and Undo on its card takes it back.")
        case .publish: String(localized: "Mux Bot doesn't put sites on the internet yet. The last step it does is Start review, then Merge, which saves your changes to the project on GitHub.")
        }
    }
}

/// A bot's thread asked the app for something; the thread on screen does it.
struct AppActionRequest: Equatable, Sendable {
    var bot: UUID
    var action: AppAction
}
