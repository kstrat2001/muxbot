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

    /// Before the panel has a size (SwiftUI's first pass is .zero), and at
    /// slivers, every size gives finite numbers: no NaN or infinite height.
    @Test(arguments: [CGSize.zero, CGSize(width: 0, height: 900), CGSize(width: 0.5, height: 0), CGSize(width: 1, height: 1),
                      CGSize(width: 900, height: 0), CGSize(width: -10, height: -10)])
    func anEmptyOrTinyPanelGivesFiniteLayouts(size: CGSize) {
        for viewport in PreviewViewport.allCases {
            let l = viewport.layout(in: size)
            #expect(l.width.isFinite && l.height.isFinite && l.scale.isFinite, "\(viewport) in \(size): \(l)")
            #expect(l.scale > 0 && l.width >= 0 && l.height >= 0, "\(viewport) in \(size): \(l)")
            let o = l.origin(in: size)
            #expect(o.x.isFinite && o.y.isFinite, "\(viewport) in \(size)")
        }
    }

    /// Double-click on the divider: the panel the page needs, so a device
    /// fills it edge to edge (no empty sides, nothing cut off).
    @Test(arguments: [PreviewViewport.phone, .smallTablet, .tablet])
    func aFittedPanelShowsTheDeviceWithNoEmptySides(_ device: PreviewViewport) throws {
        for height in [500.0, 900, 1400] as [CGFloat] {
            let width = try #require(device.fittedPanelWidth(panelHeight: height))
            let size = CGSize(width: width, height: height)
            let l = device.layout(in: size)
            let sides = width - l.width * l.scale
            #expect(sides >= 2 * PreviewViewport.devicePadding - 0.001 && sides <= 2 * PreviewViewport.devicePadding + 1,
                    "\(device.rawValue) at \(height): \(sides) of side room")
            #expect(abs(l.scale - min(1, (height - 2 * PreviewViewport.devicePadding) / l.height)) < 0.01, "as large as the height allows")
        }
    }

    @Test func aFittedPanelIsDesktopsOwnWidthAndFitHasNone() {
        #expect(PreviewViewport.desktop.fittedPanelWidth(panelHeight: 900) == 1440)
        #expect(PreviewViewport.desktop.layout(in: CGSize(width: 1440, height: 900)).scale == 1)
        #expect(PreviewViewport.fit.fittedPanelWidth(panelHeight: 900) == nil)
    }

    /// Opening the preview: the width you set wins, else the page's fit;
    /// nothing before the panel has a real height, and nothing for Fit.
    @Test func theOpeningPaneIsYourWidthElseTheFit() {
        #expect(PreviewViewport.tablet.openingPaneWidth(stored: 700, panelHeight: 900) == 700)
        #expect(PreviewViewport.tablet.openingPaneWidth(stored: nil, panelHeight: 900)
                == PreviewViewport.tablet.fittedPanelWidth(panelHeight: 900))
        #expect(PreviewViewport.tablet.openingPaneWidth(stored: nil, panelHeight: 0) == nil)
        #expect(PreviewViewport.fit.openingPaneWidth(stored: nil, panelHeight: 900) == nil)
        #expect(PreviewViewport.fit.openingPaneWidth(stored: 600, panelHeight: 900) == 600)
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
        #expect(!LocalBotState.Entry(previewPaneWidth: 700).isEmpty)
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
