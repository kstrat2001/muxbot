import Foundation
import SwiftUI
import Testing
@testable import MuxBot

/// The sidebar shows Mux Bot, the guide, as a featured tile on top (a large
/// face with its name under it); the Bots list below holds only your bots,
/// then New bot, then Activity.
struct SidebarSectionTests {
    @Test func muxBotIsFeaturedAndNotInTheList() {
        let ids = [UUID(), UUID()]
        let sections = SidebarLayout.sections(bots: ids)
        #expect(sections == [.featured(.lead), .bots(ids.map(SidebarItem.bot)), .activity])
    }

    @Test func withNoBotsTheListIsEmptyButTheTileStays() {
        #expect(SidebarLayout.sections(bots: []) == [.featured(.lead), .bots([]), .activity])
    }

    @Test func theTileIsOneElementWithAPlainLabel() {
        #expect(LeadBotTile.accessibilityName == "Mux Bot, your guide")
    }

    /// The tile, light and dark (MUXBOT_SHOTS for a look).
    @MainActor @Test func renderTheTile() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = LeadBotTile(selected: true)
                .frame(width: 240)
                .padding(16)
                .background(scheme == .dark ? Color(hex: "1e1e1e") : .white)
                .environment(\.colorScheme, scheme)
            let png = try renderPNG(view)
            try withShotsDirectory { try png.write(to: $0.appendingPathComponent("lead-tile-\(scheme == .dark ? "dark" : "light").png")) }
        }
    }
}
