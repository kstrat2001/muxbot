import Foundation
import Testing
@testable import MuxBot

/// ⌘I and the sidebar (i) open the info of the bot on screen; the lead bot
/// has none.
@Suite @MainActor
struct BotInfoShortcutTests {
    @Test func commandIOpensTheBotOnScreen() {
        let router = AppRouter()
        router.usesSidebar = true
        let id = UUID()
        router.sidebar = .bot(id)
        router.showInfo()
        #expect(router.infoBotId == id)
    }

    @Test func theLeadBotHasNoInfo() {
        let router = AppRouter()
        router.usesSidebar = true
        router.sidebar = .lead
        router.showInfo()
        #expect(router.infoBotId == nil)
        #expect(!router.canShowInfo)
    }
}
