import Foundation
import Testing
@testable import MuxBot

/// Settings › Models rows: the model id with its engine, never darkmux's
/// profile names, and whether darkmux can run it here; a failed listing is
/// said, never shown as an empty list.
struct ModelRowTests {
    let flint = DarkmuxClient.ProfileInfo(name: "flint-rec", description: "Flint, fast coder", model: "flint-int4", endpoint: "flint", reachable: true, loaded: true)
    let fold = DarkmuxClient.ProfileInfo(name: "q38-27b-tensorfold", description: nil, model: "darkmux:mlx-community/Qwen3.8-27B-4bit", endpoint: "lmstudio", reachable: true, loaded: false)
    let down = DarkmuxClient.ProfileInfo(name: "deep", description: "Deep", model: "big", endpoint: "url", reachable: false, loaded: false)

    @Test func theModelAndEngineAreTheNameNeverTheProfile() {
        let row = ModelRow(name: "flint-rec", listed: [flint], listing: .listed)
        #expect(row.title == "flint-int4")
        #expect(row.subtitle == "rec")
        #expect(row.line == "flint-int4 · rec")
        #expect(row.status == .running)
        let other = ModelRow(name: "q38-27b-tensorfold", listed: [fold], listing: .listed)
        #expect(other.line == "Qwen3.8-27B-4bit · LM Studio", "darkmux's namespace and the publisher are dropped")
        #expect(!other.line.contains("q38-27b-tensorfold"))
    }

    @Test func enginesByTheirOwnNames() {
        #expect(ModelLabel.engine("lmstudio") == "LM Studio")
        #expect(ModelLabel.engine("tensorfold") == "Tensorfold")
        #expect(ModelLabel.engine("flint") == "rec")
        #expect(ModelLabel.engine("url") == "Server")
    }

    @Test func oneEntryPerModelAndEngine() {
        var seat = fold; seat.name = "probe-27b"
        var seatUp = fold; seatUp.name = "bake38-lms"
        var foldDown = fold; foldDown.reachable = false
        #expect(ModelLabel.distinct([fold, flint, seat]).map(\.name) == ["q38-27b-tensorfold", "flint-rec"], "darkmux's order, first kept")
        #expect(ModelLabel.distinct([foldDown, seatUp]).map(\.name) == ["bake38-lms"], "the one that can run")
        var otherEngine = fold; otherEngine.name = "fold-tf"; otherEngine.endpoint = "tensorfold"
        #expect(ModelLabel.distinct([fold, otherEngine]).count == 2, "the same model on two engines is two choices")
    }

    @Test func availabilityDecidesTheBadge() {
        var p = fold
        p.availability = .init(state: "resident", reason: nil)
        #expect(ModelRow(name: p.name, listed: [p], listing: .listed).status == .running)
        p.availability = .init(state: "startable", reason: nil)
        #expect(ModelRow(name: p.name, listed: [p], listing: .listed).status == .loadsWhenUsed)
        p.availability = .init(state: "unavailable", reason: "rec isn't installed")
        let row = ModelRow(name: p.name, listed: [p], listing: .listed)
        #expect(row.status == .notRunning)
        #expect(row.detail == "rec isn't installed", "darkmux's reason, on hover")
    }

    @Test func withoutAvailabilityAnOlderDarkmuxStillReads() {
        #expect(ModelRow(name: "q38-27b-tensorfold", listed: [fold], listing: .listed).status == .loadsWhenUsed)
        #expect(ModelRow(name: "deep", listed: [down], listing: .listed).status == .notRunning)
    }

    @Test func aNameThisMacDoesntListIsSaidWithoutTheName() {
        let row = ModelRow(name: "gone", listed: [flint], listing: .listed)
        #expect(row.status == .notHere)
        #expect(row.title == "A model this Mac doesn't list")
    }

    @Test func beforeOrWithoutAListingNothingIsClaimed() {
        #expect(ModelRow(name: "flint-rec", listed: [], listing: .loading).status == .unknown)
        #expect(ModelRow(name: "flint-rec", listed: [], listing: .failed("timed out")).status == .unknown)
    }

    @Test func theBadgesSayIt() {
        #expect(ModelRow.Status.running.label == "Running")
        #expect(ModelRow.Status.loadsWhenUsed.label == "Starts when used")
        #expect(ModelRow.Status.notRunning.label == "Not available")
        #expect(ModelRow.Status.notHere.label == "Not on this Mac")
        #expect(ModelRow.Status.unknown.label == nil)
    }

    /// The listing as darkmux sends it now: `loaded` null when LM Studio
    /// didn't answer, no `error`, and the machine block.
    @Test func decodesDarkmuxsListing() throws {
        let json = #"""
        {"role":"coder","profiles":[
          {"name":"q38-27b-tensorfold","description":null,"model":"qwen3.8-27b","endpoint":"lmstudio","reachable":false,"loaded":null,"error":null},
          {"name":"flint-rec","description":"Flint","model":"flint","endpoint":"flint","reachable":true,"loaded":true,"error":null,"availability":{"state":"startable","reason":null}}
        ],"machine":{"id":"m-0123456789abcdef","name":"studio"}}
        """#
        let list = try JSONDecoder().decode(DarkmuxClient.ProfileList.self, from: Data(json.utf8))
        #expect(list.profiles.map(\.name) == ["q38-27b-tensorfold", "flint-rec"])
        #expect(list.profiles[0].loaded == nil)
        #expect(list.machine?.name == "studio")
        #expect(list.profiles[0].availability == nil, "an older darkmux")
        #expect(list.profiles[1].availability?.state == "startable")
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
