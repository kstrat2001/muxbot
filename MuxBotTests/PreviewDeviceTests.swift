import Foundation
import Testing
@testable import MuxBot

/// Device presets look like devices: the page lays out at the device's width
/// and height, scaled down (never up) to fit the panel both ways, and is
/// centered. Desktop and Fit still fill the panel.
struct PreviewDeviceLayoutTests {
    @Test func phoneInAWidePanelIsAPhoneNotAStretchedPage() {
        let l = PreviewViewport.phone.layout(in: CGSize(width: 1200, height: 900))
        #expect(l == .init(width: 390, height: 844, scale: 1, framed: true))
        #expect(l.framed)
        #expect(abs(l.origin(in: CGSize(width: 1200, height: 900)).x - 405) < 0.0001, "centered")
    }

    @Test func phoneInAShortPanelScalesDownToFitTheHeight() {
        let size = CGSize(width: 600, height: 500)
        let l = PreviewViewport.phone.layout(in: size)
        #expect(l.width == 390 && l.height == 844)
        #expect(abs(l.scale - (500 - 2 * PreviewViewport.devicePadding) / 844) < 0.0001)
        #expect(abs(l.origin(in: size).x - (600 - 390 * l.scale) / 2) < 0.0001)
    }

    struct Case: Sendable, CustomStringConvertible {
        var viewport: PreviewViewport
        var panel: CGSize
        var width: CGFloat
        var height: CGFloat
        var scale: CGFloat
        var description: String { "\(viewport) in \(Int(panel.width))×\(Int(panel.height))" }
    }

    static let cases: [Case] = [
        Case(viewport: .smallTablet, panel: CGSize(width: 1600, height: 1200), width: 768, height: 1024, scale: 1),
        Case(viewport: .smallTablet, panel: CGSize(width: 500, height: 1200), width: 768, height: 1024, scale: (500 - 32) / 768),
        Case(viewport: .tablet, panel: CGSize(width: 700, height: 900), width: 820, height: 1180, scale: (900 - 32) / 1180),
        Case(viewport: .tablet, panel: CGSize(width: 2000, height: 1400), width: 820, height: 1180, scale: 1),
    ]

    @Test(arguments: cases)
    func tabletsFitBothWays(c: Case) {
        let l = c.viewport.layout(in: c.panel)
        #expect(l.width == c.width && l.height == c.height)
        #expect(abs(l.scale - c.scale) < 0.0001, "\(c): \(l.scale)")
        #expect(l.width * l.scale <= c.panel.width && l.height * l.scale <= c.panel.height, "fits the panel")
    }

    @Test func desktopStillFillsThePanelWidth() {
        let l = PreviewViewport.desktop.layout(in: CGSize(width: 720, height: 900))
        #expect(l == .init(width: 1440, height: 1800, scale: 0.5))
        #expect(!l.framed)
        #expect(l.origin(in: CGSize(width: 720, height: 900)) == .zero)
    }

    @Test func fitIsThePanelAsIs() {
        let l = PreviewViewport.fit.layout(in: CGSize(width: 683, height: 900))
        #expect(l == .init(width: 683, height: 900, scale: 1))
        #expect(!l.framed)
    }
}

/// The device size you picked stays with the bot, on this Mac: across page
/// navigation, thread switches and relaunches. Never in the synced store.
struct PreviewDeviceMemoryTests {
    @Test func aBotRemembersItsDeviceSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("local.json")
        let a = UUID(), b = UUID()
        LocalBotState(fileURL: file).update(a) { $0.previewViewport = PreviewViewport.phone.rawValue }
        let relaunched = LocalBotState(fileURL: file)
        #expect(PreviewViewport.resolve(stored: relaunched[a]?.previewViewport, recipe: ["desktop"]) == .phone)
        #expect(PreviewViewport.resolve(stored: relaunched[b]?.previewViewport, recipe: ["desktop"]) == .desktop, "per bot")
    }

    @Test func olderFilesWithoutTheKeyStillLoad() throws {
        let json = #"{"\#(UUID().uuidString)":{"workspaceName":"hcr-x"}}"#
        let entries = try JSONDecoder().decode([String: LocalBotState.Entry].self, from: Data(json.utf8))
        #expect(entries.values.first?.previewViewport == nil)
        #expect(entries.values.first?.workspaceName == "hcr-x")
    }

    @Test func aDeviceSizeAloneIsWorthKeeping() {
        #expect(!LocalBotState.Entry(previewViewport: "tablet").isEmpty)
    }

    @Test func anUnknownStoredSizeFallsBackToTheRecipe() {
        #expect(PreviewViewport.resolve(stored: "watch", recipe: ["tablet"]) == .tablet)
        #expect(PreviewViewport.resolve(stored: nil, recipe: nil) == .fit)
    }
}

#if os(iOS)
import SwiftUI
import UIKit

/// Renders each preset through the panel's own `DeviceFrame` (a stand-in
/// page instead of the web view) for a look: set MUXBOT_SHOTS to a folder.
@Suite(.serialized) @MainActor
struct DeviceFrameRenderTests {
    @Test func renderPresetsInAWideAndANarrowPanel() throws {
        let panels = [("wide", CGSize(width: 1100, height: 800)), ("narrow", CGSize(width: 420, height: 700))]
        for (name, panel) in panels {
            for viewport in [PreviewViewport.phone, .smallTablet, .tablet, .desktop] {
                let layout = viewport.layout(in: panel)
                let page = ZStack(alignment: .topLeading) {
                    Color.white
                    LinearGradient(colors: [.purple, .teal], startPoint: .top, endPoint: .bottom).frame(height: 120)
                    Text(viewport.label).font(.system(size: 40, weight: .bold)).padding(24)
                }
                let view = page.modifier(DeviceFrame(layout: layout, panel: panel)).background(Color(white: 0.97))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let image = try #require(renderer.uiImage)
                #expect(image.size == panel, "the frame never grows past the panel")
                if let dir = ProcessInfo.processInfo.environment["MUXBOT_SHOTS"], let png = image.pngData() {
                    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(viewport.rawValue).png"))
                }
            }
        }
    }
}
#endif
