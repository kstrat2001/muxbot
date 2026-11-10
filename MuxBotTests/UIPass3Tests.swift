import Foundation
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#endif
@testable import MuxBot

/// UI pass 3: Kain's design calls.
@Suite(.serialized) @MainActor
struct UIPass3Tests {
    #if os(macOS)
    private func hex(_ color: NSColor?) -> String? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02x%02x%02x", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    /// 1: the app's accent (text, links, tab labels) is the readable green,
    /// in light and dark.
    @Test func theAccentIsTheReadableGreen() {
        let accent = NSColor(named: "AccentColor", bundle: .main)
        var light: String?, dark: String?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { light = hex(accent) }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { dark = hex(accent) }
        #expect(light == Color.accentTextLightHex)
        #expect(dark == Color.accentTextDarkHex)
    }
    #endif

    /// 4: the example bot points at Resources below, and its hello doesn't.
    @Test func theExampleBotPointsBelow() {
        #expect(BotStore.example.instructions.hasSuffix("Add a repo, folder or preview link below."))
        let hello = BotGreeting.text(name: BotStore.example.name, about: BotStore.example.instructions, hasPreview: true)
        #expect(!hello.contains("below"), "\(hello)")
    }

    /// 5: on iPhone the sheet is about your Mac and GitHub.
    @Test func thePairingSheetsTitle() {
        #expect(FleetPairingView.title(onPhone: true) == "Your Mac and GitHub")
        #expect(FleetPairingView.title(onPhone: false) == "Pair with darkmux")
    }

    /// 6: before the Mac has answered, the phone says what to do.
    @Test func thePhoneSaysWhereModelsComeFrom() {
        #expect(RunCoordinator.modelsWaitingLine(onPhone: true) == "Open Mux Bot on your Mac once to see its models.")
    }
}
