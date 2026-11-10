import Foundation
import Testing
@testable import MuxBot

/// Sweep 2, preview: the iPhone preview, Add folder, stops and reloads.
@Suite(.serialized) @MainActor
struct PreviewSweep2Tests {
    private func setUp() -> (BotStore, Bot, RunCoordinator) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-s2preview-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        runs.previewDeadline = 4
        return (store, bot, runs)
    }

    private func ready(_ port: Int = 5000) -> LivePreview { LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:\(port)/")!) }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // 1: the iPhone's full-screen preview records its bot.

    @Test func theFullScreenPreviewKnowsItsBot() {
        let preview = PreviewController()
        let bot = UUID()
        preview.showFullScreen(URL(string: "http://127.0.0.1:5000/")!, for: bot)
        #expect(preview.botId == bot, "so bug reports measure it and Point at something starts")
    }

    // 2: Add folder keeps the card and says what went wrong.

    @Test func addFolderKeepsTheOldWorkCopyUntilTheNewOneIsMade() async throws {
        let (store, bot, runs) = setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("muxbot-addfolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = https://github.com/kain/site.git\n".write(to: folder.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: folder) }
        let during = Recorder()
        runs.workspaceMaker = { _ in
            during.add(runs.livePreviews[bot.id]?.status == .settingUpWorkCopy ? "setting up" : "gone")
            throw DarkmuxClient.ClientError(message: "fatal: not a worktree", status: 500)
        }
        _ = await runs.addFolder(folder, to: bot, store: store)
        #expect(during.values == ["setting up"], "the panel shows it's being set up")
        #expect(bot.workspaceName == "site-1", "the old work copy stays until a new one is made")
        let said = (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
        #expect(said.contains { $0.contains("work copy") }, "the failure is in the thread: \(said)")
    }

    // 3: a preview for a bot you've left stops.

    @Test func aPreviewStartedOffScreenStopsAfterItsGrace() async {
        let (_, bot, runs) = setUp()
        runs.previewFetcher = { _ in ready() }
        runs.previewGraceSleep = { _ in }
        let stopped = Recorder()
        runs.previewStopper = { stopped.add($0) }
        await runs.ensurePreview(for: bot)   // e.g. a refresh after a run, thread not on screen
        await until { !stopped.values.isEmpty }
        #expect(stopped.values == ["site-1"])
    }

    @Test func aPreviewOnScreenKeepsRunning() async {
        let (_, bot, runs) = setUp()
        runs.previewFetcher = { _ in ready() }
        runs.previewGraceSleep = { _ in }
        let stopped = Recorder()
        runs.previewStopper = { stopped.add($0) }
        runs.enterThread(bot)
        await runs.ensurePreview(for: bot)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(stopped.values.isEmpty)
    }

    // 4: after a run, the page is reloaded even if the panel was closed.

    @Test func reopeningThePanelReloadsAPageThatMovedOn() {
        let preview = PreviewController()
        let bot = UUID(), url = URL(string: "http://127.0.0.1:5000/")!
        preview.show(url, for: bot, generation: 0)
        #expect(preview.loads == 1)
        preview.show(url, for: bot, generation: 0)
        #expect(preview.loads == 1, "same page, same generation: nothing")
        preview.show(url, for: bot, generation: 1)
        #expect(preview.loads == 2, "a run changed files meanwhile: reloaded")
    }

    @Test func aStatusHiccupAfterARunReloadsRatherThanRestarts() async {
        let (_, bot, runs) = setUp()
        runs.previewFetcher = { _ in ready() }
        runs.enterThread(bot)
        await runs.ensurePreview(for: bot)
        runs.previewFetcher = { _ in throw URLError(.timedOut) }
        let before = runs.previewReloads[bot.id, default: 0]
        await runs.refreshPreview(for: bot)
        #expect(runs.previewReloads[bot.id, default: 0] == before + 1)
        #expect(runs.livePreviews[bot.id]?.status == .ready, "not restarted")
    }

    // 5: done-when measures darkmux's preview of the work copy only.

    @Test func doneWhenNeverMeasuresYourOwnLink() async {
        let (store, bot, runs) = setUp()
        store.addResource(.previewURL, "http://127.0.0.1:9999/", to: bot)
        let probe = MockProbe([:])
        runs.layoutProbe = probe
        let run = store.proposeRun(task: "fix it", crew: .coder, on: bot)
        run.changedFiles = ["a.css +1 −0"]
        runs.checkSpecs[run.id] = LayoutCheck.Spec(page: URL(string: "http://127.0.0.1:5000/")!, overflowWidths: [820])
        await runs.check(run)
        #expect(probe.asked.isEmpty, "your preview link isn't the work copy")
        #expect(runs.pendingChecks.contains(run.id))
    }

    // 6: leftovers.

    @Test func aPickStaysWithItsBot() {
        let preview = PreviewController()
        let a = UUID(), b = UUID()
        preview.picked = PickedElement.fixture
        preview.pickedBot = a
        #expect(preview.pick(for: .bot(b)) == nil, "never in another bot's bar")
        #expect(preview.pick(for: .lead) == nil)
        #expect(preview.pick(for: .bot(a)) == PickedElement.fixture)
    }

    @Test func aStoppedPreviewIsForgotten() async {
        let (_, bot, runs) = setUp()
        runs.previewFetcher = { _ in ready() }
        runs.previewStopper = { _ in }
        let forgotten = Recorder()
        runs.onPreviewStopped = { forgotten.add($0.uuidString) }
        runs.enterThread(bot)
        await runs.ensurePreview(for: bot)
        await runs.stopPreview(for: bot)
        #expect(forgotten.values == [bot.id.uuidString])
        let preview = PreviewController()
        preview.show(URL(string: "http://127.0.0.1:5000/")!, for: bot.id)
        preview.forget(bot.id)
        #expect(preview.botId == nil && preview.loadedURL == nil, "its page is never measured after it stopped")
    }
}
