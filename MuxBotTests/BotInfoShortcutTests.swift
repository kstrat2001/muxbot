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

#if os(iOS)
import SwiftUI
import UIKit

/// The (i) sits in the row's layout after the status badge, never on top of
/// it (Kain, 2026-11-07: it covered the needs-you badge). Set MUXBOT_SHOTS
/// to a folder for a look.
@Suite(.serialized) @MainActor
struct SidebarInfoButtonRenderTests {
    @Test func theInfoButtonLeavesTheBadgeVisible() throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Site")
        let router = AppRouter()
        router.sidebar = .bot(bot.id)   // selected: the (i) shows
        let rowWithBadge = HStack {
            Text(bot.name)
            Spacer(minLength: 0)
            StatusBadge(kind: .needsYou)
        }
        let view = rowWithBadge
            .modifier(SidebarInfoButton(bot: bot))
            .frame(width: 220)
            .padding(8)
            .background(Color.green.opacity(0.5))
            .environment(router)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.uiImage)
        if let dir = ProcessInfo.processInfo.environment["MUXBOT_SHOTS"], let png = image.pngData() {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sidebar-info-row.png"))
        }
        #expect(image.size.width > 0, "a render for a look, not a layout assertion")
    }
}
#endif
