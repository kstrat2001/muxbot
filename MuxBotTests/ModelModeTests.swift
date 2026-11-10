import Foundation
import Testing
@testable import MuxBot

/// How a run's model is chosen: Auto (the app's order), a Default model, or
/// Always ask; app-wide in Settings, overridable per bot. A chosen model
/// that isn't running is said, never swapped silently.
struct ModelResolutionTests {
    let flint = DarkmuxClient.ProfileInfo(name: "flint-rec", description: "Flint", model: "flint", endpoint: "url", reachable: true, loaded: true)
    let fold = DarkmuxClient.ProfileInfo(name: "q38-27b-tensorfold", description: nil, model: "qwen", endpoint: "url", reachable: true, loaded: true)
    let big = DarkmuxClient.ProfileInfo(name: "bakeoff-a10b", description: nil, model: "qwen-122b", endpoint: "lmstudio", reachable: true, loaded: false)
    let order = ["flint-rec", "q38-27b-tensorfold"]
    /// darkmux's listing: the role's own (TensorFold) first, then the rest.
    var listed: [DarkmuxClient.ProfileInfo] { [fold, big, flint] }

    func resolve(_ mode: ModelMode, previous: String? = nil, rerun: Bool = false, listed: [DarkmuxClient.ProfileInfo]? = nil) -> ModelChoice {
        ModelChoice.resolve(mode: mode, order: order, listed: listed ?? self.listed, previous: previous, rerunAfterNotMet: rerun)
    }

    @Test func autoTakesTheFirstInTheOrderThatAnswers() {
        let c = resolve(.auto)
        #expect(c.profile == "flint-rec")
        #expect(c.reason == "first in your Auto order that's running")
        #expect(!c.ask && c.unavailable == nil)
    }

    @Test func autoMovesOnWhenTheDoneWhenWasntMet() {
        let c = resolve(.auto, previous: "flint-rec", rerun: true)
        #expect(c.profile == "q38-27b-tensorfold")
        #expect(c.reason == "next in your Auto order, after a done-when that wasn't met")
    }

    @Test func autoWithNoneOfItsNamesUsesDarkmuxsDefault() {
        let c = resolve(.auto, listed: [fold, big].map { var p = $0; p.name = p.name == "q38-27b-tensorfold" ? "their-coder" : p.name; return p })
        #expect(c.profile == "their-coder")
        #expect(c.reason == "darkmux's default for Coder")
    }

    @Test func nothingListedLeavesItToDarkmux() {
        let c = resolve(.auto, listed: [])
        #expect(c.profile == nil)
        #expect(c.reason == "darkmux picks (it didn't list models)")
    }

    @Test func alwaysAskPreselectsAutosPick() {
        let c = resolve(.ask)
        #expect(c.ask)
        #expect(c.profile == "flint-rec")
        #expect(c.reason == "first in your Auto order that's running")
    }

    @Test func aDefaultModelRunsEveryTime() {
        let c = resolve(.model("q38-27b-tensorfold"))
        #expect(c.profile == "q38-27b-tensorfold")
        #expect(c.reason == "your default model")
        #expect(c.unavailable == nil)
    }

    @Test func aDefaultModelStaysAfterNotMetAndOffersTheNext() {
        let c = resolve(.model("flint-rec"), previous: "flint-rec", rerun: true)
        #expect(c.profile == "flint-rec", "no auto-escalation")
        #expect(c.offerNext == "q38-27b-tensorfold")
    }

    @Test func aDefaultModelThatIsntRunningIsSaidNotSwapped() {
        var down = fold; down.reachable = false
        let c = resolve(.model("q38-27b-tensorfold"), listed: [down, big, flint])
        #expect(c.profile == "q38-27b-tensorfold", "never swapped silently")
        #expect(c.unavailable == "q38-27b-tensorfold isn't running on this Mac.")
        #expect(c.suggestion == "flint-rec", "Auto's pick, offered")
    }

    @Test func aDefaultModelThisMacDoesntListIsSaid() {
        let c = resolve(.model("gone"))
        #expect(c.profile == "gone")
        #expect(c.unavailable == "gone isn't available to Mux Bot on this Mac.")
        #expect(c.suggestion == "flint-rec")
    }
}

struct ModelModeStorageTests {
    @Test(arguments: [ModelMode.auto, .ask, .model("flint-rec")])
    func modesRoundTrip(mode: ModelMode) {
        #expect(ModelMode(stored: mode.stored) == mode)
    }

    @Test func theModeIsPerMachineAndTheOrderIsShared() {
        let store = ModelSettingsStore(backing: MemoryBacking())
        var here = store.settings(machine: "m-aaaa")
        #expect(here.mode == .auto)
        #expect(here.order == ModelSettings.defaultOrder)
        here.mode = .model("q38-27b-tensorfold")
        here.order = ["q38-27b-tensorfold", "flint-rec"]
        store.save(here, machine: "m-aaaa")
        #expect(store.settings(machine: "m-aaaa").mode == .model("q38-27b-tensorfold"))
        let other = store.settings(machine: "m-bbbb")
        #expect(other.mode == .auto, "another machine has its own models")
        #expect(other.order == ["q38-27b-tensorfold", "flint-rec"], "the Auto order is names, shared")
    }

    @Test func aBotsOverrideIsPerBotAndMachine() {
        let store = ModelSettingsStore(backing: MemoryBacking())
        let bot = UUID()
        store.setBotMode(.ask, bot: bot, machine: "m-aaaa")
        #expect(store.botMode(bot: bot, machine: "m-aaaa") == .ask)
        #expect(store.botMode(bot: bot, machine: "m-bbbb") == nil)
        #expect(store.botMode(bot: UUID(), machine: "m-aaaa") == nil)
        let app = ModelSettings(mode: .auto, order: ModelSettings.defaultOrder)
        #expect(app.mode(forBot: store.botMode(bot: bot, machine: "m-aaaa")) == .ask)
        #expect(app.mode(forBot: nil) == .auto)
        store.setBotMode(nil, bot: bot, machine: "m-aaaa")
        #expect(store.botMode(bot: bot, machine: "m-aaaa") == nil, "back to Settings")
    }

    @Test func iCloudOnlyWhenSyncIsOn() {
        #expect(ModelSettingsStore.usesICloud(cloudSync: true, hasKeyValueEntitlement: true))
        #expect(!ModelSettingsStore.usesICloud(cloudSync: false, hasKeyValueEntitlement: true))
        #expect(!ModelSettingsStore.usesICloud(cloudSync: true, hasKeyValueEntitlement: false))
    }

    @Test func darkmuxNamesTheMachine() throws {
        let json = #"{"role":"coder","profiles":[],"machine":{"id":"m-0123456789abcdef","name":"studio"}}"#
        let list = try JSONDecoder().decode(DarkmuxClient.ProfileList.self, from: Data(json.utf8))
        #expect(list.machine?.id == "m-0123456789abcdef")
        let older = try JSONDecoder().decode(DarkmuxClient.ProfileList.self, from: Data(#"{"role":"coder","profiles":[]}"#.utf8))
        #expect(older.machine == nil)
    }
}

@Suite(.serialized) @MainActor
struct ModelModeFlowTests {
    let r = ModelResolutionTests()

    private func setUp(_ settings: ModelSettings) -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        store.addResource(.previewURL, "http://127.0.0.1:5999/", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: [issueTen])
        brain.layoutProbe = MockProbe([820: heroAt(820), 768: heroAt(768), 1440: heroAt(1440)])
        let listed = r.listed
        brain.runs.profileSource = { listed }
        brain.runs.settingsStore = ModelSettingsStore(backing: MemoryBacking())
        brain.runs.settingsStore.save(settings, machine: brain.runs.machineKey)
        return (store, bot, brain)
    }

    @Test func aDefaultModelIsUsedAndStaysOnRunAgain() async throws {
        let (store, bot, brain) = setUp(ModelSettings(mode: .model("q38-27b-tensorfold"), order: ModelSettings.defaultOrder))
        await brain.send("fix #10", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        #expect(brain.runs.profile(for: run) == "q38-27b-tensorfold")
        store.apply(.approve, to: run)
        run.changedFiles = ["inertia/css/app.css +1 −1"]
        store.apply(.finish(summary: "Done."), to: run)
        await brain.rerun(run, change: "not yet", store: store, nextModel: true)
        #expect(brain.runs.profile(for: run) == "q38-27b-tensorfold")
        #expect(brain.runs.runChoices[run.id]?.offerNext == "flint-rec", "next in the order after TensorFold wraps to none: offers Auto's first")
    }

    @Test func aBotsOverrideAppliesToItsRuns() async throws {
        let (store, bot, brain) = setUp(ModelSettings(mode: .auto, order: ModelSettings.defaultOrder))
        brain.runs.settingsStore.setBotMode(.ask, bot: bot.id, machine: brain.runs.machineKey)
        await brain.send("fix #10", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        #expect(brain.runs.runChoices[run.id]?.ask == true)
        #expect(brain.runs.profile(for: run) == "flint-rec")
    }

    @Test func aDefaultModelNotMetOffersTheNextOnItsResultCard() async throws {
        let (store, bot, brain) = setUp(ModelSettings(mode: .model("flint-rec"), order: ModelSettings.defaultOrder))
        await brain.send("fix #10", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        run.changedFiles = ["inertia/css/app.css +1 −1"]
        let probe = try #require(brain.layoutProbe as? MockProbe)
        probe.facts = [820: heroAt(820), 1024: heroAt(1024), 768: heroAt(768), 1440: heroAt(1440)]   // still a row: not met
        await brain.runs.check(run)
        #expect(brain.runs.runChecks[run.id]?.met == false)
        #expect(brain.runs.runChoices[run.id]?.offerNext == "q38-27b-tensorfold")
    }

    @Test func choosingAnotherModelForOneRun() async throws {
        let (store, bot, brain) = setUp(ModelSettings(mode: .auto, order: ModelSettings.defaultOrder))
        await brain.send("fix #10", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        brain.runs.override(run, with: "q38-27b-tensorfold")
        #expect(brain.runs.profile(for: run) == "q38-27b-tensorfold")
        #expect(brain.runs.runChoices[run.id]?.reason == "chosen for this run")
        #expect(brain.runs.runChoices[run.id]?.unavailable == nil)
    }
}


/// An in-memory backing for the settings store in tests.
final class MemoryBacking: KeyValueBacking, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

@Suite(.serialized) @MainActor
struct MachineKeyTests {
    @Test func theMachineIdComesFromDarkmux() async {
        let brain = BotBrain()
        // Its own store: the machine is remembered with the settings (sweep 7 #2).
        brain.runs.settingsStore = ModelSettingsStore(backing: MemoryBacking())
        brain.runs.profileSource = { [] }
        brain.runs.machine = DarkmuxClient.Machine(id: "m-0123456789abcdef", name: "studio")
        #expect(brain.runs.machineKey == "m-0123456789abcdef")
    }

    @Test func beforeDarkmuxSaysItsTheEndpoint() {
        let brain = BotBrain()
        brain.runs.settingsStore = ModelSettingsStore(backing: MemoryBacking())
        #expect(brain.runs.machineKey == "endpoint:127.0.0.1:8767")
    }
}
