import SwiftUI
import Testing
@testable import MuxBot

/// The Setup check card in the states a new user meets, rendered from fixed
/// facts (MUXBOT_SHOTS for a look): no darkmux; darkmux without its app
/// connection (the app sees the same as no darkmux); paired with no model.
@MainActor
struct SetupStatesRenderTests {
    static func facts(_ state: Int) -> SetupFacts {
        var f = SetupFacts(platform: .mac, appleSilicon: true, memoryGB: 64, endpointUp: false, lmStudio: .notAnswering)
        f.docker = .notInstalled; f.lmStudioApp = .notInstalled
        switch state {
        case 2:   // darkmux installed, app connection not running; Docker and LM Studio installed but closed
            f.docker = .installed; f.lmStudioApp = .installed
        case 3:   // paired, no model answering, no LM Studio, Docker running
            f.endpointUp = true; f.docker = .running; f.paired = true
            f.listing = .listed; f.listedModels = 0; f.runningModels = 0
        default: break
        }
        return f
    }

    @Test(arguments: [(1, "setup-1-no-darkmux"), (2, "setup-2-no-connection"), (3, "setup-3-no-model")])
    func renderTheState(_ state: Int, _ name: String) throws {
        let view = SetupChecklistView(facts: Self.facts(state))
            .environment(FleetConnection())
            .environment(BotBrain())
            .environment(AppRouter())
            .environment(GitHubAuth())
            .frame(width: 600)
            .padding(24)
            .background(Color(hex: "1e1e1e"))
            .environment(\.colorScheme, .dark)
        let png = try renderPNG(view)
        try withShotsDirectory { try png.write(to: $0.appendingPathComponent("\(name).png")) }
        Attachment.record(png, named: "\(name).png")
        if state == 3 { #expect(SetupCheck.steps(Self.facts(3))[.models]?.detail == SetupCheck.needsEngineLine(Self.facts(3))) }
    }
}
