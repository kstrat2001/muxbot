import Foundation
import SwiftData
import Testing
@testable import MuxBot

/// Sweep batch 7: models and synced threads stay consistent across relaunch
/// and devices. In-memory stores and stubs only; nothing touches iCloud.
@Suite(.serialized) @MainActor
struct ModelsSyncSweepTests {
    // 1: one thread per bot, whichever device made it first.

    @Test func duplicateThreadsMergeIntoTheOldest() throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let old = ChatConversation(title: "site", roleId: bot.id)
        old.createdAt = Date(timeIntervalSince1970: 1_000)
        let synced = ChatConversation(title: "site", roleId: bot.id)
        synced.createdAt = Date(timeIntervalSince1970: 2_000)
        store.context.insert(old)
        store.context.insert(synced)
        store.append(.user, "from the Mac", to: old)
        store.append(.user, "from the iPhone", to: synced)
        #expect(store.existingConversation(for: .bot(bot.id))?.id == old.id, "readers take the oldest")
        let thread = store.conversation(for: .bot(bot.id))
        #expect(thread.id == old.id)
        #expect(Set((thread.messages ?? []).map(\.content)) == ["from the Mac", "from the iPhone"], "no message is lost")
        let roleId: UUID? = bot.id
        let all = try store.context.fetch(FetchDescriptor<ChatConversation>(predicate: #Predicate { $0.roleId == roleId }))
        #expect(all.count == 1)
    }

    @Test func aNewThreadsIdComesFromItsBot() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        #expect(store.conversation(for: .bot(bot.id)).id == ChatConversation.threadId(for: .bot(bot.id)))
        #expect(store.conversation(for: .lead).id == ChatConversation.threadId(for: .lead))
        #expect(ChatConversation.threadId(for: .bot(bot.id)) == ChatConversation.threadId(for: .bot(bot.id)), "the same on every device")
    }

    // 2: model settings wait for the machine's id, and remember it.

    @Test func theMachineIsRememberedAcrossRelaunchAndDevices() {
        let settings = ModelSettingsStore(backing: MemoryBacking())
        let first = RunCoordinator()
        first.settingsStore = settings
        first.machine = DarkmuxClient.Machine(id: "m-1", name: "studio")
        let relaunched = RunCoordinator()
        relaunched.settingsStore = settings
        #expect(relaunched.knownMachine == DarkmuxClient.Machine(id: "m-1", name: "studio"))
        #expect(relaunched.machineKey == "m-1")
    }

    @Test func noModelSettingIsSavedBeforeTheMachineIsKnown() {
        let runs = RunCoordinator()
        runs.settingsStore = ModelSettingsStore(backing: MemoryBacking())
        #expect(runs.knownMachine == nil)
        #expect(!GuideSettings.setModelMode(.ask, runs: runs))
        #expect(runs.currentModelSettings().mode == .auto, "nothing went to a placeholder key")
        runs.machine = DarkmuxClient.Machine(id: "m-1", name: "studio")
        #expect(GuideSettings.setModelMode(.ask, runs: runs))
        #expect(runs.settingsStore.settings(machine: "m-1").mode == .ask)
    }

    @Test func theMachineIsNamedForTheDevice() {
        let studio = DarkmuxClient.Machine(id: "m-1", name: "studio")
        #expect(RunCoordinator.machinePhrase(studio, onPhone: true) == "your Mac (studio)")
        #expect(RunCoordinator.machinePhrase(nil, onPhone: true) == "your Mac")
        #expect(RunCoordinator.machinePhrase(studio, onPhone: false) == "studio")
        #expect(RunCoordinator.machinePhrase(nil, onPhone: false) == "this Mac")
    }

    // 3: Always ask and a missing default model are never skipped.

    private func runReady(mode: ModelMode) -> (BotStore, BotRun, BotBrain, Recorder) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.runs.deviceRuns = true
        brain.runs.settingsStore = ModelSettingsStore(backing: MemoryBacking())
        brain.runs.machine = DarkmuxClient.Machine(id: "m-1", name: "studio")
        brain.runs.settingsStore.save(ModelSettings(mode: mode), machine: "m-1")
        brain.runs.profileSource = { [DarkmuxClient.ProfileInfo(name: "flint-rec", endpoint: "http://127.0.0.1:1234", reachable: true)] }
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-sweep7-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        brain.runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        brain.runs.pollInterval = 0.02
        let sent = Recorder()
        brain.runs.workSubmitter = { _, _, profile, _, _ in sent.add(profile ?? "-"); return ("w-1", profile) }
        brain.runs.workStatusFetcher = { _ in try JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(#"{"status":"running"}"#.utf8)) }
        // Proposed on another device, or before a relaunch: no choice here yet.
        let run = store.proposeRun(task: "Make it warm", crew: .coder, on: bot)
        return (store, run, brain, sent)
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func alwaysAskShowsThePickerBeforeAnApproveGoesThrough() async {
        let (store, run, brain, sent) = runReady(mode: .ask)
        brain.runs.decide(.approve, on: run, store: store)
        await brain.runs.choosingModel[run.id]?.value
        #expect(brain.runs.runChoices[run.id]?.ask == true)
        #expect(run.phase == .proposed, "it waits for the picker")
        #expect(sent.values.isEmpty)
        // The card now shows the picker; Approve confirms it.
        brain.runs.decide(.approve, on: run, store: store)
        await until { !sent.values.isEmpty }
        #expect(sent.values == ["flint-rec"])
        run.phase = .canceled
    }

    @Test func aDefaultModelThatsGoneIsSaidNotSkipped() async {
        let (store, run, brain, sent) = runReady(mode: .model("gone-model"))
        brain.runs.decide(.approve, on: run, store: store)
        await brain.runs.choosingModel[run.id]?.value
        #expect(brain.runs.runChoices[run.id]?.unavailable != nil)
        #expect(run.phase == .proposed)
        #expect(sent.values.isEmpty)
    }

    @Test func autoStillApprovesInOneTap() async {
        let (store, run, brain, sent) = runReady(mode: .auto)
        brain.runs.decide(.approve, on: run, store: store)
        await brain.runs.choosingModel[run.id]?.value
        await until { !sent.values.isEmpty }
        #expect(sent.values == ["flint-rec"])
        run.phase = .canceled
    }

    // 5: each crew gets its own role's models.

    @Test func aReviewerRunGetsTheReviewersModels() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let runs = RunCoordinator()
        runs.settingsStore = ModelSettingsStore(backing: MemoryBacking())
        let roles = Recorder()
        runs.profileSourceByRole = { role in
            roles.add(role)
            return [DarkmuxClient.ProfileInfo(name: role == "code-reviewer" ? "reviewer-model" : "coder-model", endpoint: "e", reachable: true)]
        }
        let review = store.proposeRun(task: "Review it", crew: .reviewer, on: bot)
        await runs.chooseProfile(for: review)
        #expect(roles.values == ["code-reviewer"])
        #expect(runs.profile(for: review) == "reviewer-model")
        #expect(runs.listed(for: review).map(\.name) == ["reviewer-model"])
    }

    @Test func theProfilesRequestNamesTheRole() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /client/profiles", 200, #"{"role":"code-reviewer","profiles":[]}"#)
        _ = try await DarkmuxClient(session: GitHubStub.session).profiles(token: "t", role: "code-reviewer")
        #expect(GitHubStub.seen.last?.query == "role=code-reviewer")
    }

    // 6: Search and tab navigation.

    @Test func tabLayoutNeverStacksTheSameThread() {
        let router = AppRouter()
        router.usesSidebar = false
        let id = UUID()
        router.navigate(to: .bot(id))
        router.navigate(to: .bot(id))
        #expect(router.path == [.bot(id)])
    }

    @Test func searchShowsTheBotsNameNow() {
        let store = TestStore.fresh()
        let bot = store.add(name: "Old name", instructions: "")
        let message = store.append(.user, "hello", to: store.conversation(for: .bot(bot.id)))
        bot.name = "New name"
        #expect(SearchView.threadName(for: message, bots: store.allBots()) == "New name")
    }

    @Test func aMessageResultOpensAtTheMessage() {
        let router = AppRouter()
        let id = UUID(), message = UUID()
        router.open(message: message, in: .bot(id))
        #expect(router.focusMessageId == message)
        #expect(router.context == .bot(id))
    }

    // 7: a bot deleted on another device.

    @Test func aDeletedBotsThreadIsLeft() {
        let router = AppRouter()
        router.usesSidebar = true
        let gone = UUID(), kept = UUID()
        router.sidebar = .bot(gone)
        router.botsChanged(existing: [kept])
        #expect(router.sidebar == .lead)
        let tabs = AppRouter()
        tabs.path = [.bot(kept), .bot(gone)]
        tabs.botsChanged(existing: [kept])
        #expect(tabs.path == [.bot(kept)])
    }

    @Test func aMissingBotGetsNoThread() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let gone = UUID()
        await brain.send("hello", in: .bot(gone), store: store)
        #expect(store.existingConversation(for: .bot(gone)) == nil)
    }
}
