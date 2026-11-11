import Foundation
import Testing
@testable import MuxBot

/// The app picks the model per run, from what darkmux says this app may run
/// here (`GET /client/profiles`, in the owner's grant order) and what answers
/// now; a run whose done-when isn't met runs again on the next one.
struct ModelPreferenceTests {
    let flint = DarkmuxClient.ProfileInfo(name: "flint-rec", description: "Flint", model: "flint", endpoint: "url", reachable: true, loaded: true)
    let fold = DarkmuxClient.ProfileInfo(name: "q38-27b-tensorfold", description: nil, model: "mlx-community/Qwen3.8-27B-4bit", endpoint: "url", reachable: true, loaded: true)

    /// What darkmux lists with clients.profiles unset: the role's own first,
    /// then every other local profile, alphabetically.
    func listing(_ own: DarkmuxClient.ProfileInfo, _ rest: [DarkmuxClient.ProfileInfo]) -> [DarkmuxClient.ProfileInfo] { [own] + rest }
    let big = DarkmuxClient.ProfileInfo(name: "bakeoff-a10b", description: nil, model: "qwen3.5-122b", endpoint: "lmstudio", reachable: true, loaded: false)

    @Test func thePreferredModelThatAnswersGoesFirst() {
        #expect(ModelPreference.first(in: listing(fold, [big, flint]), order: testOrder) == "flint-rec", "fast coder first, wherever darkmux lists it")
        var down = flint; down.reachable = false
        #expect(ModelPreference.first(in: listing(fold, [big, down]), order: testOrder) == "q38-27b-tensorfold")
        #expect(ModelPreference.first(in: []) == nil, "none listed: darkmux's own default")
    }

    @Test func withoutPreferredNamesItsDarkmuxsDefault() {
        let own = DarkmuxClient.ProfileInfo(name: "their-coder", description: nil, model: "m", endpoint: "lmstudio", reachable: true, loaded: true)
        #expect(ModelPreference.first(in: listing(own, [big]), order: testOrder) == "their-coder", "the role's own, listed first")
        #expect(ModelPreference.next(after: "their-coder", in: listing(own, [big]), order: testOrder) == "their-coder", "never wanders to another local model")
    }

    @Test func notMetMovesToTheNextPreferred() {
        #expect(ModelPreference.next(after: "flint-rec", in: listing(fold, [big, flint]), order: testOrder) == "q38-27b-tensorfold")
        #expect(ModelPreference.next(after: "q38-27b-tensorfold", in: listing(fold, [big, flint]), order: testOrder) == "q38-27b-tensorfold", "the last stays")
        #expect(ModelPreference.next(after: nil, in: listing(fold, [big, flint]), order: testOrder) == "flint-rec")
    }

    /// The run's model went down: the next one after it in the order that
    /// answers, never the one that's down.
    @Test func notMetWhenTheCurrentModelIsDownMovesOnFromItsPlace() {
        var down = flint; down.reachable = false
        #expect(ModelPreference.next(after: "flint-rec", in: listing(fold, [big, down]), order: testOrder) == "q38-27b-tensorfold")
        let deep = DarkmuxClient.ProfileInfo(name: "deep", description: nil, model: "d", endpoint: "url", reachable: true, loaded: true)
        let order = ["flint-rec", "q38-27b-tensorfold", "deep"]
        var foldDown = fold; foldDown.reachable = false
        #expect(ModelPreference.next(after: "flint-rec", in: [down, foldDown, deep], order: order) == "deep", "skips the next one when it's down too")
        #expect(ModelPreference.next(after: "q38-27b-tensorfold", in: [flint, foldDown], order: order) == "flint-rec",
                "the last one down: the strongest that still answers")
        #expect(ModelPreference.next(after: "flint-rec", in: [down], order: order) == nil, "nothing answers: darkmux decides")
    }

    @Test func aDefaultModelThatsDownOffersOneThatAnswers() {
        var down = flint; down.reachable = false
        let c = ModelChoice.resolve(mode: .model("flint-rec"), order: testOrder, listed: [down, fold],
                                    previous: "flint-rec", rerunAfterNotMet: true)
        #expect(c.offerNext == "q38-27b-tensorfold")
    }

    /// A saved "Always <model>" that this Mac doesn't list still has a row in
    /// the picker, so the saved value shows instead of a blank picker.
    @Test func aSavedModelNotListedHereStillHasAPickerRow() {
        #expect(ModelMode.unlistedModel(.model("gone"), listed: ["flint-rec"]) == "gone")
        #expect(ModelMode.unlistedModel(.model("flint-rec"), listed: ["flint-rec"]) == nil)
        #expect(ModelMode.unlistedModel(.auto, listed: []) == nil)
        #expect(ModelMode.unlistedModel(nil, listed: []) == nil)
    }

    @Test func darkmuxsReplyDecodes() throws {
        let json = #"{"role":"coder","profiles":[{"name":"flint-rec","description":"Flint","model":"flint","endpoint":"url","reachable":true,"loaded":true},{"name":"gone","description":null,"model":null,"endpoint":"unknown","reachable":false,"loaded":null,"error":"not in the registry"}]}"#
        let list = try JSONDecoder().decode(DarkmuxClient.ProfileList.self, from: Data(json.utf8))
        #expect(list.profiles.map(\.name) == ["flint-rec", "gone"])
        #expect(list.profiles[1].reachable == false)
        #expect(list.profiles[1].error == "not in the registry")
    }
}

@Suite(.serialized) @MainActor
struct ModelChoiceFlowTests {
    let listed = [ModelPreferenceTests().flint, ModelPreferenceTests().fold]

    private func setUp() -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        store.addResource(.previewURL, "http://127.0.0.1:5999/", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: [issueTen])
        brain.layoutProbe = MockProbe([820: heroAt(820), 768: heroAt(768), 1440: heroAt(1440)])
        let listed = self.listed
        brain.runs.profileSource = { listed }
        // The app ships no Auto order; these runs use the test one.
        brain.runs.settingsStore = ModelSettingsStore(backing: MemoryBacking())
        brain.runs.settingsStore.save(ModelSettings(order: testOrder), machine: brain.runs.machineKey)
        return (store, bot, brain)
    }

    @Test func aDispatchGetsTheFirstModelThatAnswers() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("fix #10", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        #expect(brain.runs.runProfiles[run.id] == "flint-rec")
        #expect(brain.runs.profile(for: run) == "flint-rec", "what startRealRun sends")
    }

    @Test func runAgainAfterNotMetUsesTheNextModel() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("fix #10", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        store.apply(.approve, to: run)
        run.changedFiles = ["inertia/css/app.css +40 −0"]
        store.apply(.finish(summary: "Done."), to: run)
        let notMet = LayoutCheck.Result(met: false, failures: ["At 1024px section.hero.container.flex is a row, not a column."])
        await brain.rerun(run, change: LayoutCheck.rerunChange(notMet), store: store, nextModel: true)
        #expect(brain.runs.runProfiles[run.id] == "q38-27b-tensorfold")
    }

    @Test func aReplyKeepsTheSameModel() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("fix #10", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        store.apply(.approve, to: run)
        store.apply(.finish(summary: "Done."), to: run)
        await brain.rerun(run, change: "make it bolder", store: store)
        #expect(brain.runs.runProfiles[run.id] == "flint-rec")
    }

    @Test func nothingListedLeavesItToDarkmux() async throws {
        let (store, bot, brain) = setUp()
        brain.runs.profileSource = { [] }
        await brain.send("fix #10", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        #expect(brain.runs.profile(for: run) == nil)
    }
}
