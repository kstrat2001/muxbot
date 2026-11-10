import Foundation
import Testing
@testable import MuxBot

/// Sweep 2, state: runs on another Mac, deletes elsewhere, relaunch.
@Suite(.serialized) @MainActor
struct StateRestSweep2Tests {
    private func setUp() -> (BotStore, Bot, RunCoordinator) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-state-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        runs.pollInterval = 0.02
        runs.profileSource = { [] }
        runs.deviceRuns = true
        runs.adoptionDefaults = UserDefaults(suiteName: "muxbot-tests-adopt-\(UUID().uuidString)")!
        return (store, bot, runs)
    }

    private func status(_ json: String) -> DarkmuxClient.WorkStatus {
        try! JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(json.utf8))
    }

    private func said(_ store: BotStore, _ bot: Bot) -> [String] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }.map(\.content)
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // 3: a reply to another Mac's result goes there.

    @Test func aTweakOfAnotherMacsRunIsRefused() {
        let (store, bot, runs) = setUp()
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        run.darkmuxWorkId = "w-1"
        run.changedFiles = ["a.css +1 −0"]
        run.keptCommit = "c1"
        store.apply(.finish(summary: "done"), to: run)
        let sent = Recorder()
        runs.workSubmitter = { _, _, _, _, _ in sent.add("x"); return ("w-2", nil) }
        runs.tweak("make it blue", run: run, store: store)
        #expect(run.phase == .result)
        #expect(sent.values.isEmpty)
        #expect(said(store, bot).last == "Reply on the Mac it ran on.")
    }

    // 4: deleting a bot while another Mac runs it.

    @Test func aBotRunningOnAnotherMacIsntDeletedHere() async {
        let (store, bot, runs) = setUp()
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        run.darkmuxWorkId = "w-1"
        let problem = await runs.prepareToDelete(bot, store: store)
        #expect(problem?.contains("Mac it runs on") == true, "\(problem ?? "nil")")
        #expect(run.phase == .running)
    }

    @Test func aBotDeletedElsewhereStopsItsRunsAndPreviewHere() async {
        let (store, bot, runs) = setUp()
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        run.darkmuxWorkId = "w-1"
        runs.markStartedHere(run)
        runs.workStatusFetcher = { _ in status(#"{"status":"running"}"#) }
        runs.previewFetcher = { _ in LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:5000/")!) }
        let stopped = Recorder(), cancelled = Recorder()
        runs.previewStopper = { stopped.add($0) }
        runs.workCanceller = { cancelled.add($0) }
        runs.enterThread(bot)
        await runs.ensurePreview(for: bot)
        let follow = Task { await runs.follow(run, workId: "w-1", store: store) }
        try? await Task.sleep(for: .milliseconds(60))
        await runs.botDisappeared(bot.id)
        #expect(cancelled.values == ["w-1"])
        #expect(stopped.values == ["site-1"])
        run.phase = .canceled
        await follow.value
    }

    // 6: reopening the window doesn't resume twice.

    @Test func reopeningTheWindowLeavesAQueuedRunWaiting() async {
        let (store, bot, runs) = setUp()
        runs.resumeFollowing(store: store)   // launch
        runs.workSubmitter = { _, _, _, _, _ in throw DarkmuxClient.ClientError(message: "too many", status: 429) }
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        runs.decide(.approve, on: run, store: store)
        await until { said(store, bot).contains(RunCoordinator.waitingForSlot) }
        runs.resumeFollowing(store: store)   // the window opened again
        #expect(run.phase == .running, "still waiting for a slot, not \"quit before darkmux started it\"")
        run.phase = .canceled
    }

    // 7: adopting old runs, once.

    @Test func oldRunsAreAdoptedOnceAndARunningOneIsChecked() async {
        let (store, bot, runs) = setUp()
        let done = store.proposeRun(task: "old", crew: .coder, on: bot)
        store.apply(.approve, to: done)
        store.apply(.finish(summary: "ok"), to: done)
        let going = store.proposeRun(task: "going", crew: .coder, on: bot)
        store.apply(.approve, to: going)
        going.darkmuxWorkId = "w-old"
        runs.adoptLegacyRuns(store: store)
        #expect(done.startedHere && going.startedHere)
        // darkmux doesn't know it: it wasn't this Mac's, and it isn't failed.
        runs.workStatusFetcher = { _ in throw DarkmuxClient.ClientError(message: "no such run", status: 404) }
        await runs.follow(going, workId: "w-old", store: store)
        #expect(going.phase == .running)
        #expect(!going.startedHere)
        // A bot that just never ran here isn't adopted later.
        let other = store.add(name: "other", instructions: "")
        other.workspaceName = "other-1"
        let theirs = store.proposeRun(task: "theirs", crew: .coder, on: other)
        store.apply(.approve, to: theirs)
        store.apply(.finish(summary: "ok"), to: theirs)
        runs.adoptLegacyRuns(store: store)
        #expect(!theirs.startedHere, "adopted once per install, never again")
    }

    // 8 + 9: a revoked pairing is said as such.

    @Test func aRevokedPairingIsntCantReach() {
        #expect(SettingCardView.whoamiFailure(DarkmuxClient.ClientError(message: "unknown token", status: 401)) == FleetConnection.revokedMessage)
        #expect(SettingCardView.whoamiFailure(URLError(.cannotConnectToHost)) == "Can't reach darkmux")
        #expect(RunCoordinator.stopUnpaired.contains("Mac with darkmux"), "a new pairing can't reach the old run")
    }
}
