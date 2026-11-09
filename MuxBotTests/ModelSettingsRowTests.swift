import Foundation
import Testing
@testable import MuxBot

/// Settings › Models rows: the profile's description as its name with the
/// id under it, and whether it's running here; a failed listing is said,
/// never shown as an empty list.
struct ModelRowTests {
    let flint = DarkmuxClient.ProfileInfo(name: "flint-rec", description: "Flint, fast coder", model: "flint", endpoint: "url", reachable: true, loaded: true)
    let fold = DarkmuxClient.ProfileInfo(name: "q38-27b-tensorfold", description: nil, model: "qwen", endpoint: "lmstudio", reachable: true, loaded: false)
    let down = DarkmuxClient.ProfileInfo(name: "deep", description: "Deep", model: "big", endpoint: "url", reachable: false, loaded: false)

    @Test func theDescriptionIsTheNameAndTheIdSitsUnder() {
        let row = ModelRow(name: "flint-rec", listed: [flint], listing: .listed)
        #expect(row.title == "Flint, fast coder")
        #expect(row.subtitle == "flint-rec")
        #expect(row.status == .running)
    }

    @Test(arguments: [
        ("Flint eval (2026-10-22): identical to `bake38-splash` except the PRIMARY.", "Flint eval (2026-10-22)"),
        ("Single-turn tasks. Slim primary, no compactor.", "Single-turn tasks"),
        ("Review probe-high seat — Qwen3.8 27B (qwen/qwen3.8-27b).", "Review probe-high seat"),
        ("Coder\nsecond line", "Coder"),
        ("qwen3.5-122b-a10b-text-mlx tuned for long agentic / multi-turn (bake-off candidate A).", "qwen3.5-122b-a10b-text-mlx tuned for long agentic…"),
    ])
    func aLongDescriptionGivesItsLeadingPhrase(description: String, title: String) {
        var p = flint; p.description = description
        let row = ModelRow(name: "flint-rec", listed: [p], listing: .listed)
        #expect(row.title == title)
        #expect(row.detail == description, "the whole description, on hover")
    }

    @Test func withoutADescriptionTheIdIsTheName() {
        let row = ModelRow(name: "q38-27b-tensorfold", listed: [fold], listing: .listed)
        #expect(row.title == "q38-27b-tensorfold")
        #expect(row.subtitle == nil)
        #expect(row.status == .loadsWhenUsed, "LM Studio answers; darkmux loads it for the run")
    }

    @Test func aServerThatDoesntAnswerIsNotRunning() {
        #expect(ModelRow(name: "deep", listed: [down], listing: .listed).status == .notRunning)
    }

    @Test func aNameThisMacDoesntListIsSaid() {
        #expect(ModelRow(name: "gone", listed: [flint], listing: .listed).status == .notHere)
    }

    @Test func beforeOrWithoutAListingNothingIsClaimed() {
        #expect(ModelRow(name: "flint-rec", listed: [], listing: .loading).status == .unknown)
        #expect(ModelRow(name: "flint-rec", listed: [], listing: .failed("timed out")).status == .unknown)
    }

    @Test func theBadgesSayIt() {
        #expect(ModelRow.Status.running.label == "Running")
        #expect(ModelRow.Status.loadsWhenUsed.label == "Loads when used")
        #expect(ModelRow.Status.notRunning.label == "Not running")
        #expect(ModelRow.Status.notHere.label == "Not on this Mac")
        #expect(ModelRow.Status.unknown.label == nil)
    }

    /// The listing as darkmux sends it now: `loaded` null when LM Studio
    /// didn't answer, no `error`, and the machine block.
    @Test func decodesDarkmuxsListing() throws {
        let json = #"""
        {"role":"coder","profiles":[
          {"name":"q38-27b-tensorfold","description":null,"model":"qwen3.8-27b","endpoint":"lmstudio","reachable":false,"loaded":null,"error":null},
          {"name":"flint-rec","description":"Flint","model":"flint","endpoint":"url","reachable":true,"loaded":true,"error":null}
        ],"machine":{"id":"m-0123456789abcdef","name":"studio"}}
        """#
        let list = try JSONDecoder().decode(DarkmuxClient.ProfileList.self, from: Data(json.utf8))
        #expect(list.profiles.map(\.name) == ["q38-27b-tensorfold", "flint-rec"])
        #expect(list.profiles[0].loaded == nil)
        #expect(list.machine?.name == "studio")
    }
}

@Suite(.serialized) @MainActor
struct ProfileListingTests {
    struct Timeout: Error, LocalizedError { var errorDescription: String? { "The request timed out." } }

    @Test func aFailedListingIsKeptAndSaid() async {
        let brain = BotBrain()
        brain.runs.profileSource = { throw Timeout() }
        let got = await brain.runs.listedProfiles()
        #expect(got.isEmpty)
        #expect(brain.runs.listing == .failed("The request timed out."))
    }

    @Test func aListingNamesTheMachine() async {
        let brain = BotBrain()
        let flint = ModelRowTests().flint
        brain.runs.profileSource = { [flint] }
        let got = await brain.runs.listedProfiles()
        #expect(got == [flint])
        #expect(brain.runs.listing == .listed)
    }
}
