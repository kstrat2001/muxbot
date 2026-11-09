import Foundation
import Testing
@testable import MuxBot

struct PreviewServiceTests {
    private let resource = URL(string: "http://example.test:8445/")!
    private let darkmux = URL(string: "http://127.0.0.1:51234/")!

    @Test func darkmuxsReadyPreviewWins() {
        let ready = LivePreview(status: .ready, url: darkmux)
        #expect(LivePreview.url(darkmux: ready, resource: resource) == darkmux)
    }

    @Test func whileItStartsTheresNoURLYet() {
        for status in [LivePreview.Status.starting, .installing, .failed("boom")] {
            #expect(LivePreview.url(darkmux: LivePreview(status: status, url: darkmux), resource: resource) == nil)
        }
    }

    @Test func withoutDarkmuxYourLinkIsUsed() {
        #expect(LivePreview.url(darkmux: nil, resource: resource) == resource)
        #expect(LivePreview.url(darkmux: LivePreview(status: .stopped, url: darkmux), resource: resource) == resource)
    }

    @Test func statusInPlainWords() {
        #expect(LivePreview.Status.starting.text == "Starting the preview…")
        #expect(LivePreview.Status.installing.text == "Installing the project's dependencies (first time only)…")
        #expect(LivePreview.Status.failed("the dev server exited (exit status: 1)").text == "The preview couldn't start.")
    }

    @Test func darkmuxsReplyDecodes() throws {
        let json = #"{"workspace":"hcr","status":"failed","url":"http://127.0.0.1:5000/","port":5000,"hmr_port":5001,"error":"exited","log_tail":"boom"}"#
        let p = try JSONDecoder().decode(DarkmuxClient.Preview.self, from: Data(json.utf8))
        #expect(p.live == LivePreview(status: .failed("exited"), url: URL(string: "http://127.0.0.1:5000/")!, log: "boom"))
        let ready = try JSONDecoder().decode(DarkmuxClient.Preview.self, from: Data(#"{"status":"ready","url":"http://127.0.0.1:5000/"}"#.utf8))
        #expect(ready.live.status == .ready)
    }
}

/// At launch the darkmux connection isn't attached yet: the preview says it's
/// waiting (never a blank panel) and starts once the connection appears.
@Suite(.serialized) @MainActor
struct PreviewWaitingTests {
    @Test func withoutTheConnectionThePreviewSaysItsWaiting() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        bot.workspaceName = "hcr-test"
        let runs = RunCoordinator()
        await runs.ensurePreview(for: bot)
        #expect(runs.livePreviews[bot.id]?.status == .waiting)
        #expect(LivePreview.Status.waiting.text == "Waiting for darkmux…")
        #expect(LivePreview.url(darkmux: runs.livePreviews[bot.id], resource: URL(string: "http://example.test/")) == nil)
        bot.workspaceName = nil
    }

    @Test func theConnectionAppearingRetriesWaitingPreviews() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        bot.workspaceName = "hcr-test"
        let runs = RunCoordinator()
        await runs.ensurePreview(for: bot)
        var retried: [UUID] = []
        runs.retryPreview = { retried.append($0.id) }
        runs.connectionAttached()
        await Task.yield()
        #expect(retried == [bot.id])
        bot.workspaceName = nil
    }

    @Test func aBotWithoutAWorkCopyHasNothingToWaitFor() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        let runs = RunCoordinator()
        await runs.ensurePreview(for: bot)
        #expect(runs.livePreviews[bot.id] == nil)
    }
}

/// Previews don't outlive what you're looking at: leaving a bot or quitting
/// stops them, and the one on screen keeps telling darkmux it's wanted.
@Suite(.serialized) @MainActor
struct PreviewLifetimeTests {
    private func setUp(_ name: String = "site") -> (BotStore, Bot, RunCoordinator) {
        let store = TestStore.fresh()
        let bot = store.add(name: name, instructions: "")
        bot.workspaceName = "\(name)-1"
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-lifetime-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        runs.previewFetcher = { _ in LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:5000/")!) }
        return (store, bot, runs)
    }

    @Test func quittingStopsEveryRunningPreview() async {
        let (store, a, runs) = setUp()
        let b = store.add(name: "blog", instructions: "")
        b.workspaceName = "blog-1"
        await runs.ensurePreview(for: a)
        await runs.ensurePreview(for: b)
        let stopped = Recorder()
        runs.previewStopper = { stopped.add($0) }
        await runs.stopAllPreviews()
        #expect(Set(stopped.values) == ["site-1", "blog-1"])
        #expect(runs.livePreviews[a.id]?.status == .stopped)
        #expect(runs.livePreviews[b.id]?.status == .stopped)
    }

    @Test func quittingWithNothingRunningAsksDarkmuxNothing() async {
        let (_, a, runs) = setUp()
        await runs.ensurePreview(for: a)
        let stopped = Recorder()
        runs.previewStopper = { stopped.add($0) }
        await runs.stopPreview(for: a)
        await runs.stopAllPreviews()
        #expect(stopped.values == ["site-1"], "only the one stop, from leaving the bot")
    }

    @Test func quittingNeverHangsOnASlowDarkmux() async {
        let (_, a, runs) = setUp()
        await runs.ensurePreview(for: a)
        runs.previewStopper = { _ in try? await Task.sleep(for: .seconds(30)) }
        let start = ContinuousClock.now
        await runs.stopAllPreviews(limit: .milliseconds(200))
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func leavingABotWhileItWaitsMeansItNeverStartsLater() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let runs = RunCoordinator()
        await runs.ensurePreview(for: bot)
        #expect(runs.livePreviews[bot.id]?.status == .waiting)
        await runs.stopPreview(for: bot)
        var retried: [UUID] = []
        runs.retryPreview = { retried.append($0.id) }
        runs.connectionAttached()
        #expect(retried.isEmpty)
        #expect(runs.livePreviews[bot.id]?.status == .stopped)
    }

    @Test func thePreviewOnScreenFollowsDarkmux() async {
        let (_, bot, runs) = setUp()
        await runs.ensurePreview(for: bot)
        runs.previewHeartbeat = .milliseconds(20)
        let asked = Recorder()
        runs.previewFetcher = { _ in asked.add("status"); return LivePreview(status: .stopped) }
        let alive = Task { await runs.keepPreviewAlive(for: bot) }
        try? await Task.sleep(for: .milliseconds(300))
        alive.cancel()
        await alive.value
        #expect(!asked.values.isEmpty, "it asked darkmux while on screen")
        #expect(runs.livePreviews[bot.id]?.status == .stopped, "darkmux stopped it (idle): the app shows that")
    }
}
