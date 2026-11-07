import SwiftUI

enum AppTab: Hashable {
    case bots, work
}

/// The macOS / iPad sidebar: Mux Bot, each bot, and Work.
enum SidebarItem: Hashable {
    case lead, bot(UUID), work
}

@MainActor @Observable
final class AppRouter {
    var tab: AppTab = .bots
    var path: [Route] = []
    /// Sidebar layout (macOS, iPad): the selected row picks the thread
    /// directly, with no Home grid and no back button.
    var usesSidebar = false
    var sidebar: SidebarItem? = .lead
    var showNewBot = false
    var showPairing = false
    /// Text waiting in the bot bar, e.g. from Fleet's "Ask <bot> about this".
    var barDraft = ""
    /// The live preview panel beside (or above) the thread on screen.
    var showPreview = false
    /// iPhone: the preview fills the thread (handy for picking).
    var previewFullScreen = false

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

    /// Picking an element (or "Ask about this" / "Report a bug here") in the
    /// full-screen preview goes back to the chat, where the chip waits.
    func returnToChatAfterPick() {
        showPreview = false
        previewFullScreen = false
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
