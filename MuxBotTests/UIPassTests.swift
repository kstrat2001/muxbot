import Foundation
import SwiftUI
import Testing
@testable import MuxBot

/// UI pass 1: what the screens say and how readable it is.
@Suite(.serialized) @MainActor
struct UIPassTests {
    /// The on-device model failing says so plainly: never the framework's
    /// error name or code.
    @Test func aModelFailureIsPlain() {
        struct Failed: LocalizedError { var errorDescription: String? { "The operation couldn’t be completed. (FoundationModels.LanguageModelSession.GenerationError error -1.)" } }
        let reason = BotBrain.modelFailureReason(Failed())
        #expect(!reason.contains("FoundationModels") && !reason.contains("-1"), "\(reason)")
        #expect(!reason.isEmpty)
    }

    /// Without the model, "make the header bigger" is still a request for
    /// Coder, not "I can only act on clear requests".
    @Test(arguments: ["make the header text bigger", "change the title to Tides", "can you remove the footer"])
    func aChangeIsWorkWithoutTheModel(_ text: String) {
        let bot = BotSummary(id: UUID(), name: "site", instructions: "", state: .ready, resources: [])
        let turn = FallbackBrain.turn(for: text, speaker: bot, bots: [bot])
        guard case let .dispatch(crew, _)? = turn.action else { Issue.record("\(text): \(turn.reply)"); return }
        #expect(crew == .coder)
    }

    /// The Start form's suggestion text is readable on its chip: 4.5:1 in
    /// light and dark.
    @Test func suggestionTextIsReadable() {
        let lightChip = ContrastTests.RGB(hex: "e5e5ea"), darkChip = ContrastTests.RGB(hex: "3a3a3c")
        let light = ContrastTests.RGB(hex: Color.accentTextLightHex), dark = ContrastTests.RGB(hex: Color.accentTextDarkHex)
        #expect(ContrastTests.ratio(light, lightChip) >= 4.5)
        #expect(ContrastTests.ratio(dark, darkChip) >= 4.5)
    }
}
