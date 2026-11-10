import Foundation
import Testing
@testable import MuxBot

/// The setup check sees Docker and LM Studio as apps (installed, open), and
/// never hands you a Terminal command for them: a button or an official page.
struct SetupDetectionTests {
    private func facts(docker: SetupFacts.AppPresence = .unknown, lm: SetupFacts.LMStudio = .notAnswering,
                       lmApp: SetupFacts.AppPresence = .unknown) -> SetupFacts {
        var f = SetupFacts(platform: .mac, appleSilicon: true, memoryGB: 128, endpointUp: true, lmStudio: lm)
        f.docker = docker; f.lmStudioApp = lmApp
        return f
    }

    @Test func presenceFromWhatTheMacReports() {
        #expect(SetupCheck.presence(installed: false, running: false) == .notInstalled)
        #expect(SetupCheck.presence(installed: true, running: false) == .installed)
        #expect(SetupCheck.presence(installed: true, running: true) == .running)
        #expect(SetupCheck.presence(installed: false, running: true) == .running, "running from somewhere LaunchServices doesn't list")
    }

    @Test func dockerRunningIsDone() {
        let step = SetupCheck.steps(facts(docker: .running))[.docker]
        #expect(step?.state == .done)
        #expect(step?.action == nil && step?.link == nil)
    }

    @Test func dockerInstalledButClosedOffersToOpenIt() {
        let step = SetupCheck.steps(facts(docker: .installed))[.docker]
        #expect(step?.state == .todo)
        #expect(step?.detail == "Docker Desktop is installed but not open. Open it and leave it running.")
        #expect(step?.action == .openDocker)
    }

    @Test func dockerMissingLinksDockersOwnInstallPage() {
        let step = SetupCheck.steps(facts(docker: .notInstalled))[.docker]
        #expect(step?.state == .todo)
        #expect(step?.link?.absoluteString == "https://docs.docker.com/desktop/setup/install/mac-install/")
        #expect(step?.linkTitle == "Get Docker Desktop")
    }

    /// Only where the app can't look does it ask you.
    @Test func dockerUnknownFallsBackToAsking() {
        let step = SetupCheck.steps(facts(docker: .unknown))[.docker]
        #expect(step?.state == .manual)
        #expect(step?.action == .confirmDocker)
    }

    @Test func lmStudioInstalledButNotServingOffersToOpenIt() {
        let step = SetupCheck.steps(facts(lmApp: .installed))[.lmStudio]
        #expect(step?.state == .todo)
        #expect(step?.action == .openLMStudio)
        #expect(step?.detail.hasPrefix("LM Studio is installed, but its local server isn't answering.") == true)
    }

    @Test func lmStudioMissingLinksItsSite() {
        let step = SetupCheck.steps(facts(lmApp: .notInstalled))[.lmStudio]
        #expect(step?.link == SetupCheck.lmStudioURL)
        #expect(step?.linkTitle == "Get LM Studio")
    }

    /// No step offers brew for Docker or LM Studio, in any state (a step
    /// has no command field at all).
    @Test func noBrewForApps() {
        for d in [SetupFacts.AppPresence.unknown, .notInstalled, .installed, .running] {
            for l in [SetupFacts.AppPresence.unknown, .notInstalled, .installed, .running] {
                let steps = SetupCheck.steps(facts(docker: d, lmApp: l))
                for id in [SetupStep.ID.docker, .lmStudio] { #expect(steps[id]?.detail.contains("brew") != true) }
            }
        }
    }
}
