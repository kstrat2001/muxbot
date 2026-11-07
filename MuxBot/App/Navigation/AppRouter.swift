import SwiftUI

enum AppTab: Hashable {
    case bots, fleet
}

@MainActor @Observable
final class AppRouter {
    var tab: AppTab = .bots
    var path: [Route] = []
    var showNewRole = false
    /// Text waiting in the bot bar, e.g. from Fleet's "Ask <bot> about this".
    var barDraft = ""

    /// Follows navigation: whichever bot's thread is on top is the one you
    /// talk to; Home and the lead bot's thread talk to the lead bot.
    var context: ChatContext {
        switch path.last {
        case let .bot(id): .bot(id)
        case .lead, nil: .lead
        }
    }

    func navigate(to route: Route) {
        path.append(route)
    }

    /// Opens a thread on the Bots tab with a draft ready to send.
    func ask(_ context: ChatContext, draft: String) {
        tab = .bots
        switch context {
        case .lead: path = [.lead]
        case let .bot(id): path = [.bot(id)]
        }
        barDraft = draft
    }
}
