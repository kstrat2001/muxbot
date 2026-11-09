import Foundation
import Testing
@testable import MuxBot

/// After a run changes files (or Undo puts them back), the preview you have
/// open shows the result: reloaded when it's live, restarted when it isn't,
/// and never a stale page standing in for a stopped one.
@Suite(.serialized) @MainActor
struct PreviewRefreshTests {
    final class Fake: @unchecked Sendable {
        var startStatus: LivePreview.Status = .ready
        var statusNow: LivePreview.Status = .ready
        let starts = Recorder()
    }

    private func setUp() -> (BotStore, Bot, BotBrain, Fake) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-refresh-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        brain.runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        let fake = Fake()
        brain.runs.previewFetcher = { start in
            if start { fake.starts.add("start") }
            return LivePreview(status: start ? fake.startStatus : fake.statusNow, url: URL(string: "http://127.0.0.1:5000/")!)
        }
        return (store, bot, brain, fake)
    }

    private func finish(_ run: BotRun, changes: Bool, brain: BotBrain, store: BotStore) async {
        run.phase = .running
        let json = changes
            ? #"{"status":"done","changes":{"files":[{"path":"src/styles.css","added":1,"removed":1}]},"commit":"abc1234","branch":"mux/site"}"#
            : #"{"status":"done","result":{"final_assistant":"Which page?"}}"#
        await brain.runs.finishRun(run, status: try! JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(json.utf8)), store: store)
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func aRunThatChangedFilesReloadsTheLivePreview() async {
        let (store, bot, brain, fake) = setUp()
        await brain.runs.ensurePreview(for: bot)
        let run = store.proposeRun(task: "Make it warm", crew: .coder, on: bot)
        await finish(run, changes: true, brain: brain, store: store)
        await until { brain.runs.previewReloads[bot.id] != nil }
        #expect(brain.runs.previewReloads[bot.id] == 1)
        #expect(fake.starts.values == ["start"], "a live preview is reloaded, not restarted")
    }

    @Test func aRunThatChangedNothingLeavesThePreviewAlone() async {
        let (store, bot, brain, _) = setUp()
        await brain.runs.ensurePreview(for: bot)
        let run = store.proposeRun(task: "Which page?", crew: .coder, on: bot)
        await finish(run, changes: false, brain: brain, store: store)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(brain.runs.previewReloads[bot.id] == nil)
    }

    @Test func aPreviewThatStoppedIsRestartedAfterTheRun() async {
        let (store, bot, brain, fake) = setUp()
        await brain.runs.ensurePreview(for: bot)
        fake.statusNow = .failed("darkmux stopped answering")
        let run = store.proposeRun(task: "Make it warm", crew: .coder, on: bot)
        await finish(run, changes: true, brain: brain, store: store)
        await until { fake.starts.values.count == 2 }
        #expect(fake.starts.values == ["start", "start"])
        await until { brain.runs.livePreviews[bot.id]?.status == .ready }
        #expect(brain.runs.livePreviews[bot.id]?.status == .ready)
    }

    @Test func aStoppedPreviewIsNeverShownAsAPage() async {
        let (store, bot, brain, fake) = setUp()
        await brain.runs.ensurePreview(for: bot)
        fake.statusNow = .failed("darkmux stopped answering")
        fake.startStatus = .failed("the dev server exited")
        let run = store.proposeRun(task: "Make it warm", crew: .coder, on: bot)
        await finish(run, changes: true, brain: brain, store: store)
        await until { fake.starts.values.count == 2 }
        await until { brain.runs.livePreviews[bot.id]?.status.isFailed == true }
        #expect(brain.runs.previewURL(for: bot) == nil, "the panel shows the status card, not the old page")
    }

    @Test func undoReloadsTheLivePreview() async {
        let (store, bot, brain, _) = setUp()
        await brain.runs.ensurePreview(for: bot)
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        run.phase = .result
        run.changedFiles = ["a.css +1 −1"]
        run.keptCommit = "abc1234"
        run.darkmuxWorkId = "w-1"
        brain.runs.markStartedHere(run)
        brain.runs.workUndoer = { _ in DarkmuxClient.UndoResult.fixture }
        brain.runs.decide(.discard, on: run, store: store)
        await until { brain.runs.previewReloads[bot.id] != nil }
        #expect(run.phase == .discarded)
        #expect(brain.runs.previewReloads[bot.id] == 1)
    }

    @Test func aPreviewNobodyOpenedIsNotStartedByARun() async {
        let (store, bot, brain, fake) = setUp()
        let run = store.proposeRun(task: "Make it warm", crew: .coder, on: bot)
        await finish(run, changes: true, brain: brain, store: store)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fake.starts.values.isEmpty)
        #expect(brain.runs.previewReloads[bot.id] == nil)
    }
}
