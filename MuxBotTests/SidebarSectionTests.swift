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

    /// The tile, light and dark, for review.
    @MainActor @Test func renderTheTile() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = LeadBotTile(selected: true)
                .frame(width: 240)
                .padding(16)
                .background(scheme == .dark ? Color(nsColor: NSColor(hex: "1e1e1e")) : .white)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("lead-tile-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
