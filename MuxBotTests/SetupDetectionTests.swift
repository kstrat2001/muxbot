import Foundation
import Testing
@testable import MuxBot

/// The setup check sees LM Studio as an app (installed, open), and
/// never hands you a Terminal command for them: a button or an official page.
struct SetupDetectionTests {
    private func facts(lm: SetupFacts.LMStudio = .notAnswering,
                       lmApp: SetupFacts.AppPresence = .unknown) -> SetupFacts {
        var f = SetupFacts(platform: .mac, appleSilicon: true, memoryGB: 128, endpointUp: true, lmStudio: lm)
        f.lmStudioApp = lmApp
        return f
    }

    @Test func presenceFromWhatTheMacReports() {
        #expect(SetupCheck.presence(installed: false, running: false) == .notInstalled)
        #expect(SetupCheck.presence(installed: true, running: false) == .installed)
        #expect(SetupCheck.presence(installed: true, running: true) == .running)
        #expect(SetupCheck.presence(installed: false, running: true) == .running, "running from somewhere LaunchServices doesn't list")
    }

    @Test func lmStudioInstalledButNotServingOffersToOpenIt() {
        let step = SetupCheck.steps(facts(lmApp: .installed))[.lmStudio]
        #expect(step?.state == .optional)
        #expect(step?.action == .openLMStudio)
        #expect(step?.detail.hasPrefix("LM Studio is installed, but its local server isn't answering.") == true)
    }

    @Test func lmStudioMissingLinksItsSite() {
        let step = SetupCheck.steps(facts(lmApp: .notInstalled))[.lmStudio]
        #expect(step?.link == SetupCheck.lmStudioURL)
        #expect(step?.linkTitle == "Get LM Studio")
    }

    /// No step offers brew for LM Studio, in any state (a step
    /// has no command field at all).
    @Test func noBrewForApps() {
        do {
            for l in [SetupFacts.AppPresence.unknown, .notInstalled, .installed, .running] {
                let steps = SetupCheck.steps(facts(lmApp: l))
                for id in [SetupStep.ID.lmStudio] { #expect(steps[id]?.detail.contains("brew") != true) }
            }
        }
    }
}
