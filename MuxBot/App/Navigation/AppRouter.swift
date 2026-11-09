import SwiftUI

enum AppTab: Hashable {
    case bots, activity
}

/// The macOS / iPad sidebar: Mux Bot, each bot, and Activity.
enum SidebarItem: Hashable {
    case lead, bot(UUID), activity
}

@MainActor @Observable
final class AppRouter {
    var tab: AppTab = .bots
    var path: [Route] = [] {
        // Another thread: the full-window preview was the bot before's.
        didSet { if path != oldValue { previewFullScreen = false } }
    }
    /// Sidebar layout (macOS, iPad): the selected row picks the thread
    /// directly, with no Home grid and no back button.
    var usesSidebar = false
    var sidebar: SidebarItem? = .lead {
        didSet { if sidebar != oldValue { previewFullScreen = false } }
    }
    /// The Mac / iPad sidebar's own show-hide state (the toolbar toggle).
    var columnVisibility: NavigationSplitViewVisibility = .all
    var showNewBot = false
    /// "What do you want to get done?" (`StartProjectView`).
    var showStartProject = false
    var showPairing = false
    /// Search across bots and threads (⌘F).
    var showSearch = false
    /// Bumped to put the cursor in the chat bar (⌘L).
    var focusBarRequest = 0
    /// Text waiting in the bot bar, e.g. from Fleet's "Ask <bot> about this".
    var barDraft = ""
    /// The live preview panel beside (or above) the thread on screen.
    var showPreview = false {
        // Hiding the preview brings the sidebar and its toggle back.
        didSet { if !showPreview { previewFullScreen = false } }
    }
    /// iPhone: the preview fills the thread (handy for picking).
    var previewFullScreen = false
    /// A run to scroll to (and briefly highlight) in its bot's conversation.
    var focusRunId: UUID?
    /// The bot whose info is open (macOS: a popover on its sidebar row).
    var infoBotId: UUID?

    /// With no bots yet, the window opens on "What do you want to get
    /// done?" (the sidebar's empty selection shows the chooser); Mux Bot's
    /// row still opens the guide.
    func openOnStart(botCount: Int) {
        if usesSidebar, botCount == 0, sidebar == .lead, path.isEmpty { sidebar = nil }
    }

    /// Paired, with no bots yet: straight on to starting a project.
    func continueAfterPairing(botCount: Int) {
        guard botCount == 0 else { return }
        path = []
        if usesSidebar { sidebar = nil } else { tab = .bots }
    }

    /// Whether the thread on screen is a bot's (the lead bot has no info).
    var canShowInfo: Bool { context.botId != nil }

    /// ⌘I: the info of the bot on screen. It's a popover on the bot's
    /// sidebar row, so a collapsed sidebar (or a full-window preview) comes
    /// back first.
    func showInfo() {
        infoBotId = context.botId
        guard infoBotId != nil else { return }
        if columnVisibility == .detailOnly { columnVisibility = .all }
        if previewFullScreen { previewFullScreen = false }
    }

    /// Follows navigation: whichever bot's thread is on top is the one you
    /// talk to; Home and the lead bot's thread talk to the lead bot.
    var context: ChatContext {
        switch path.last {
        case let .bot(id): return .bot(id)
        case .lead: return .lead
        case nil:
            if usesSidebar, case let .bot(id)? = sidebar { return .bot(id) }
            return .lead
        }
    }

    /// Picking an element (or "Chat about this" on selected text) in the
    /// full-screen preview goes back to the chat, where the chip waits.
    /// A reply or a card that needs you arrived in the thread on screen:
    /// leave the full-window preview so it's seen (the preview stays open
    /// beside the chat).
    func attentionArrived() {
        if previewFullScreen { previewFullScreen = false }
    }

    func returnToChatAfterPick() {
        showPreview = false
        previewFullScreen = false
    }

    /// Opens a run's bot conversation at the run's card.
    func open(_ run: BotRun) {
        guard let bot = run.bot else { return }
        tab = .bots
        focusRunId = run.id
        if usesSidebar { path = []; sidebar = .bot(bot.id) } else { path = [.bot(bot.id)] }
    }

    func navigate(to route: Route) {
        guard usesSidebar else { path.append(route); return }
        path = []
        switch route {
        case .lead: sidebar = .lead
        case let .bot(id): sidebar = .bot(id)
        }
    }

    /// Opens a thread on the Bots tab with a draft ready to send.
    func ask(_ context: ChatContext, draft: String) {
        tab = .bots
        if usesSidebar {
            path = []
            sidebar = context.botId.map { .bot($0) } ?? .lead
        } else {
            switch context {
            case .lead: path = [.lead]
            case let .bot(id): path = [.bot(id)]
            }
        }
        barDraft = draft
    }
}
