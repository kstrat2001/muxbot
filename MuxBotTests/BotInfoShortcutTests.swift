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

/// The (i) sits in the row's layout before the status badge, never on top
/// of it (Kain, 2026-11-07: it covered the needs-you badge). Renders the
/// real sidebar row, selected and hovered, with a short and a long name;
/// set MUXBOT_SHOTS to a folder for a look.
@Suite(.serialized) @MainActor
struct SidebarInfoButtonRenderTests {
    @Test func theInfoButtonSitsBeforeTheBadge() throws {
        let id = UUID()
        let cases: [(String, String, Bool)] = [
            ("selected", "humancodereader", true),
            ("hovered-long", "A very long bot name that has to truncate", false),
        ]
        var images: [UIImage] = []
        for (_, name, selected) in cases {
            let router = AppRouter()
            router.sidebar = selected ? .bot(id) : .lead
            let view = BotSidebar.row(name: name, look: .lead, id: id, unread: true, state: .needsYou)
                .environment(\.sidebarInfo, SidebarInfoContext(enabled: true, hovering: !selected))
                .environment(router)
                .frame(width: 260)
                .padding(8)
                .background(selected ? Color.green.opacity(0.5) : Color.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            images.append(try #require(renderer.uiImage))
        }
        if let dir = ProcessInfo.processInfo.environment["MUXBOT_SHOTS"] {
            for (image, c) in zip(images, cases) {
                try image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sidebar-row-\(c.0).png"))
            }
        }
        #expect(images.allSatisfy { $0.size.width == 276 }, "a render for a look")
    }
}
#endif
