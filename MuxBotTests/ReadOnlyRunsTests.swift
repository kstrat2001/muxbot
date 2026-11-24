import Foundation
import Testing
@testable import MuxBot

/// muxbot#144 step 6 (darkmux #3682): a darkmux that runs reporting crews
/// with a read-only work copy gets Researcher as its `researcher` role. A
/// reporting run that committed anyway (that machine's own role file can
/// write) is still put back; an older darkmux keeps `analyst`.
@Suite(.serialized) @MainActor
struct ReadOnlyRunsTests {
    private func setUp(capabilities: Set<String>) -> (BotStore, Bot, RunCoordinator) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-readonly-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        runs.pollInterval = 0.02
        runs.profileSource = { [] }
        runs.deviceRuns = true
        runs.useOnDeviceModel = false
        runs.capabilitiesSource = { capabilities }
        return (store, bot, runs)
    }

    private func status(_ json: String) -> DarkmuxClient.WorkStatus {
        try! JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(json.utf8))
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// A research run that (somehow) committed: what darkmux reports.
    private let committed = #"{"status":"done","result":{"final_assistant":"It's in main.swift."},"commit":"abc1234","branch":"mux/site-1","undone":false}"#

    @Test func researcherGoesToTheReadOnlyRoleAndACommitIsStillPutBack() async {
        let (store, bot, runs) = setUp(capabilities: ["read_only_runs"])
        let roles = Recorder()
        let undone = Recorder()
        runs.workSubmitter = { role, _, _, _, _ in roles.add(role); return ("w-1", nil) }
        runs.workStatusFetcher = { [self] _ in status(committed) }
        runs.workUndoer = { id in undone.add(id); throw DarkmuxClient.ClientError(message: "nothing to undo", status: 409) }
        let run = store.proposeRun(task: "Where is the header set?", crew: .researcher, on: bot)
        runs.decide(.approve, on: run, store: store)
        await until { !undone.values.isEmpty }
        #expect(roles.values == ["researcher"], "\(roles.values)")
        #expect(undone.values == ["w-1"], "darkmux reported a commit, so it's put back: \(undone.values)")
    }

    @Test func anOlderDarkmuxKeepsAnalystAndTheSafetyNet() async {
        let (store, bot, runs) = setUp(capabilities: [])
        let roles = Recorder()
        let undone = Recorder()
        runs.workSubmitter = { role, _, _, _, _ in roles.add(role); return ("w-1", nil) }
        runs.workStatusFetcher = { [self] _ in status(committed) }
        runs.workUndoer = { id in undone.add(id); throw DarkmuxClient.ClientError(message: "nothing to undo", status: 409) }
        let run = store.proposeRun(task: "Where is the header set?", crew: .researcher, on: bot)
        runs.decide(.approve, on: run, store: store)
        await until { !undone.values.isEmpty }
        #expect(roles.values == ["analyst"], "\(roles.values)")
        #expect(undone.values == ["w-1"], "its edits are put back: \(undone.values)")
    }

    @Test func theReviewerKeepsItsRoleEitherWay() {
        let runs = RunCoordinator()
        runs.darkmuxCapabilities = ["read_only_runs"]
        #expect(runs.role(for: .reviewer) == "code-reviewer")
        #expect(runs.role(for: .coder) == "coder")
        runs.darkmuxCapabilities = []
        #expect(runs.role(for: .researcher) == "analyst")
    }
}
