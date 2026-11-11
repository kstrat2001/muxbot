import Foundation
import Testing
@testable import MuxBot

/// The pairing sheet's first step makes sense on its own: darkmux has no
/// window, so it approves new apps from its own setup on the Mac, and its
/// guide shows how. Never a command (the no-commands rule).
struct PairingStepTests {
    @Test func stepOneSaysHowDarkmuxApproves() {
        let text = FleetPairingView.approveStep
        #expect(text == "darkmux has no window to click: it approves new apps from its own setup on this Mac. Its guide shows how.")
        #expect(NoCommands.says(text) == nil)
    }
}
