import Foundation
import Testing
@testable import MuxBot

/// Kain (2026-11-12): no Docker anywhere. darkmux on a Mac runs work in
/// macOS's own sandbox, and previews are moving off Docker too, so Mux Bot
/// never names Docker or containers: no setup row, no detection, no help.
@MainActor
struct NoDockerTests {
    static func saysDocker(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("docker") || t.contains("container")
    }

    @Test func theSetupCheckHasNoDockerStep() {
        #expect(!SetupStep.ID.allCases.map(\.rawValue).contains("docker"))
        var facts = SetupFacts(platform: .mac, appleSilicon: true, memoryGB: 64, endpointUp: true, lmStudio: .models(2))
        facts.paired = true; facts.listing = .listed; facts.listedModels = 1; facts.runningModels = 1
        let steps = SetupCheck.steps(facts)
        #expect(SetupCheck.summary(steps) == "All set", "no Docker needed for All set")
        for f in [facts, SetupFacts(platform: .mac, appleSilicon: true, memoryGB: 64, endpointUp: false), SetupFacts(platform: .phone, appleSilicon: false, memoryGB: 8)] {
            for step in SetupCheck.steps(f) { #expect(!Self.saysDocker(step.title + step.detail), "\(step.id)") }
        }
        #expect(!Self.saysDocker(SetupCheck.shareText()))
    }

    /// darkmux 5.10+ under its Seatbelt sandbox refuses a preview (403,
    /// naming its Docker setting): this darkmux can't run previews here yet.
    @Test func darkmuxsSeatbeltRefusalNeedsANewerDarkmux() {
        let refusal = "previews need `runtime.sandbox` `docker` for now: a preview runs in a Docker container, and this machine's sandbox is `seatbelt`. To run previews here: `darkmux config set runtime.sandbox docker` (Docker installed and running)"
        let why = LivePreview.Unavailable.from(status: 403, message: refusal, template: false, code: "forbidden")
        #expect(why == .needsNewerDarkmux)
        #expect(LivePreview.Unavailable.needsNewerDarkmux.detail(repo: nil, folder: nil) == "Live previews need a newer darkmux on this Mac. darkmux's guide shows how to update.")
    }

    @Test func previewWordsNeverNameDocker() {
        for why in [LivePreview.Unavailable.previewsOff, .notAnswering, .earlierPairing, .noRecipe, .notYourCheckout, .checkoutMoved, .newProject, .templateNoRecipe, .remakeProject, .notPaired, .needsNewerDarkmux] {
            #expect(!Self.saysDocker(why.title + " " + why.detail(repo: "o/r", folder: "f")), "\(why)")
        }
        // An older darkmux's reasons still arrive; their words don't name Docker.
        for reason in ["a preview runs in a container: darkmux's runtime requires Docker, which isn't running",
                       "the preview container did not start (exit 125)",
                       "the dev server listens on 127.0.0.1 inside its container; set it to bind 0.0.0.0"] {
            let f = PreviewFailure(reason: reason, log: nil)
            #expect(!Self.saysDocker(f.headline + " " + f.explanation), "\(reason)")
            #expect(NoCommands.says(f.explanation) == nil)
        }
    }

    @Test func helpNeverNamesDocker() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MuxBot/Features/Guide/Help")
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "md" {
            #expect(!Self.saysDocker(try String(contentsOf: file, encoding: .utf8)), "\(file.lastPathComponent)")
        }
    }
}
