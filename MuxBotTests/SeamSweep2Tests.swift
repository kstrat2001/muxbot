import Foundation
import Testing
@testable import MuxBot

/// Sweep 2, the app-to-darkmux seam (traced against darkmux 5.10).
@Suite(.serialized) @MainActor
struct SeamSweep2Tests {
    private func setUp(pairing: String = "pairing-A") -> (BotStore, Bot, RunCoordinator) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-seam-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        defaults.set(pairing, forKey: FleetConnection.pairingIdKey)
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        runs.pollInterval = 0.02
        runs.profileSource = { [] }
        runs.deviceRuns = true
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

    private func running(_ store: BotStore, _ bot: Bot, _ runs: RunCoordinator, workId: String) -> BotRun {
        let run = store.proposeRun(task: "Make it warm", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        run.darkmuxWorkId = workId
        runs.markStartedHere(run)
        runs.recordWork(workId, for: run)
        return run
    }

    // 1: a turn that committed nothing never blocks Undo.

    @Test func aTurnWithNoCommitIsntUndone() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs, workId: "w-1")
        await runs.finishRun(run, status: status(#"{"status":"done","commit":"c1","branch":"mux/site","changes":{"files":[{"path":"a.css","added":1,"removed":0}]}}"#), store: store)
        // A Tweak that changed nothing.
        store.apply(.tweak, to: run)
        run.darkmuxWorkId = "w-2"
        runs.recordWork("w-2", for: run)
        await runs.finishRun(run, status: status(#"{"status":"done","changes":{"files":[]}}"#), store: store)
        #expect(runs.workIds(for: run) == ["w-1"], "only turns with a commit are undone")
    }

    @Test func darkmuxSayingNothingToUndoMovesOn() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs, workId: "w-1")
        runs.recordWork("w-2", for: run)
        run.changedFiles = ["a.css +1 −0"]
        run.keptCommit = "c2"
        store.apply(.finish(summary: "done"), to: run)
        let undone = Recorder()
        runs.workUndoer = { id in
            undone.add(id)
            if id == "w-1" { throw DarkmuxClient.ClientError(message: "the run changed nothing; there's nothing to undo", status: 409) }
            return DarkmuxClient.UndoResult(revert: "r", files: ["a.css"])
        }
        runs.decide(.discard, on: run, store: store)
        await until { run.phase == .discarded }
        #expect(undone.values == ["w-2", "w-1"])
        #expect(run.phase == .discarded, "\(runs.decisionErrors[run.id] ?? "")")
    }

    // 2: a stopped or failed run's left-behind commit.

    @Test func leftBehindIsDecoded() {
        let s = status(#"{"status":"cancelled","commit":"abc","branch":"mux/site","files":["a.css","b.css"]}"#)
        #expect(s.commit == "abc" && s.leftFiles == ["a.css", "b.css"])
        let o = status(#"{"status":"error","error":"x","commit":"abc","files":[{"path":"a.css"}]}"#)
        #expect(o.leftFiles == ["a.css"])
    }

    @Test func aStoppedRunsLeftBehindCanBeUndone() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs, workId: "w-1")
        runs.workStatusFetcher = { _ in status(#"{"status":"cancelled","commit":"abc","branch":"mux/site","files":["a.css"]}"#) }
        await runs.follow(run, workId: "w-1", store: store)
        #expect(run.phase == .canceled)
        #expect(run.keptCommit == "abc")
        #expect(RunCardState.canUndo(run))
        #expect(said(store, bot).contains { $0.contains("a.css") && $0.contains("checkpoint") }, "\(said(store, bot))")
    }

    @Test func aTweakThatFailedAfterEditingIsntCalledUnchanged() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs, workId: "w-1")
        run.changedFiles = ["a.css +1 −0"]
        run.keptCommit = "c1"
        store.apply(.finish(summary: "done"), to: run)
        runs.workSubmitter = { _, _, _, _, _ in ("w-2", nil) }
        runs.workStatusFetcher = { _ in status(#"{"status":"error","error":"boom","commit":"c2","branch":"mux/site","files":["b.css"]}"#) }
        runs.tweak("make it blue", run: run, store: store)
        await until { run.phase == .result && run.keptCommit == "c2" }
        #expect(run.changedFiles.contains { $0.hasPrefix("b.css") } && run.changedFiles.contains { $0.hasPrefix("a.css") })
        #expect(!(said(store, bot).last ?? "").contains("unchanged"), "\(said(store, bot).last ?? "")")
    }

    // 3: a work copy from an earlier pairing.

    @Test func anEarlierPairingsWorkCopyIsSaidPlainly() {
        let refused = DarkmuxClient.ClientError(message: "workspace site-1 was not made for this app", status: 403)
        let sentence = DarkmuxPlain.sentence(refused)
        #expect(sentence.contains("earlier pairing") && !sentence.contains("403"), "\(sentence)")
        // No claim command any more (Kain's rule): New work copy instead.
        #expect(sentence.contains("New work copy"))
        #expect(LivePreview.Unavailable.from(status: 403, message: refused.message, template: false, code: nil) == .earlierPairing)
    }

    @Test func aRunFromBeforeARepairIsNotADarkmuxRestart() async {
        let (store, bot, runs) = setUp(pairing: "pairing-B")
        let run = running(store, bot, runs, workId: "w-1")
        runs.recordPairing("pairing-A", for: run)
        runs.workStatusFetcher = { _ in throw DarkmuxClient.ClientError(message: "no such run", status: 404) }
        await runs.follow(run, workId: "w-1", store: store)
        #expect(run.phase == .failed)
        #expect(run.summary.contains("earlier pairing"), "\(run.summary)")
    }

    // 4: a run waiting for a slot doesn't wait forever.

    @Test func aQueuedRunIsRetried() async {
        let (store, bot, runs) = setUp()
        runs.queueRetryInterval = .milliseconds(30)
        let calls = Recorder()
        runs.workSubmitter = { _, _, _, _, _ in
            calls.add("x")
            if calls.values.count == 1 { throw DarkmuxClient.ClientError(message: "too many", status: 429) }
            return ("w-9", nil)
        }
        runs.workStatusFetcher = { _ in status(#"{"status":"running"}"#) }
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        runs.decide(.approve, on: run, store: store)
        await until { run.darkmuxWorkId == "w-9" }
        #expect(run.darkmuxWorkId == "w-9")
        run.phase = .canceled
    }

    // 5: permanent 409s aren't "busy".

    @Test func aPermanentRefusalIsntBusy() {
        for message in ["no free workspace name for this repo", "the work copy isn't on a branch", "no origin default branch"] {
            let s = DarkmuxPlain.sentence(DarkmuxClient.ClientError(message: message, status: 409))
            #expect(!s.contains("busy"), "\(message): \(s)")
        }
    }

    @Test func theBotNameFitsDarkmuxsWorkspaceName() throws {
        let body = DarkmuxClient.WorkspaceBody(repoURL: "https://github.com/kain/site", sourcePath: nil, bot: String(repeating: "b", count: 50))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        #expect((json?["bot"] as? String)?.count == 31)
    }

    // 6: the heartbeat says a refusal, not "not answering".

    @Test func theHeartbeatSaysARefusalPlainly() async {
        let (_, bot, runs) = setUp()
        runs.livePreviews[bot.id] = LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:5000/")!)
        runs.previewHeartbeat = .milliseconds(10)
        runs.previewFetcher = { _ in throw DarkmuxClient.ClientError(message: "previews are off", status: 403, code: "preview_disabled") }
        let beat = Task { await runs.keepPreviewAlive(for: bot) }
        await until { runs.livePreviews[bot.id]?.status != .ready }
        beat.cancel()
        #expect(runs.livePreviews[bot.id]?.status == .unavailable(.previewsOff))
    }

    // 7: a clone's branch is the default branch: Open PR uses mux/<bot>.

    @Test func aCloneOnItsDefaultBranchPushesToItsOwnBranch() {
        let (_, bot, runs) = setUp()
        let changes = DarkmuxClient.Changes(base: "b0", baseBranch: "main", head: "h", branch: "main", files: [])
        #expect(runs.pushStart(bot, changes: changes)?.head == "mux/site")
    }

    // 8: pairing failures are plain.

    @Test func aPairingFailureIsPlain() {
        let text = FleetConnection.plainError(DarkmuxClient.ClientError(message: "internal error: db locked", status: 500))
        #expect(!text.contains("db locked"), "\(text)")
    }

    // 9: the clean-start probe caches only a real answer.

    @Test func theCleanStartProbeKnowsOnly400And404() {
        #expect(DarkmuxClient.supportsCleanStart(probeStatus: 400) == true)
        #expect(DarkmuxClient.supportsCleanStart(probeStatus: 404) == false)
        #expect(DarkmuxClient.supportsCleanStart(probeStatus: 503) == nil)
        #expect(DarkmuxClient.supportsCleanStart(probeStatus: 401) == nil)
    }
}
