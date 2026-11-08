import Foundation
import Testing
@testable import MuxBot

/// The app picks the model per run, from what darkmux says this app may run
/// here (`GET /client/profiles`, in the owner's grant order) and what answers
/// now; a run whose done-when isn't met runs again on the next one.
struct ModelPreferenceTests {
    let flint = DarkmuxClient.ProfileInfo(name: "flint-rec", description: "Flint", model: "flint", endpoint: "url", reachable: true, loaded: true)
    let fold = DarkmuxClient.ProfileInfo(name: "q38-27b-tensorfold", description: nil, model: "mlx-community/Qwen3.8-27B-4bit", endpoint: "url", reachable: true, loaded: true)

    @Test func theFirstListedThatAnswersGoesFirst() {
        #expect(ModelPreference.first(in: [flint, fold]) == "flint-rec")
        var down = flint; down.reachable = false
        #expect(ModelPreference.first(in: [down, fold]) == "q38-27b-tensorfold")
        #expect(ModelPreference.first(in: []) == nil, "none listed: darkmux's own default")
    }

    @Test func notMetMovesToTheNextOne() {
        #expect(ModelPreference.next(after: "flint-rec", in: [flint, fold]) == "q38-27b-tensorfold")
        #expect(ModelPreference.next(after: "q38-27b-tensorfold", in: [flint, fold]) == "q38-27b-tensorfold", "the last one stays")
        #expect(ModelPreference.next(after: nil, in: [flint, fold]) == "flint-rec")
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
