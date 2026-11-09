import Foundation
import Testing
@testable import MuxBot

/// Batch 1 of the sweep: one main window, so a run is followed once (no
/// double notifications or backups), and a full-window preview never
/// outlives its bot or hides what needs you.
@Suite(.serialized) @MainActor
struct OneWindowTests {
    @Test func aRunIsFollowedOnceHoweverOftenFollowingResumes() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-onewindow-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        run.phase = .running
        run.darkmuxWorkId = "w-1"
        let polls = Recorder()
        let gate = Gate()
        runs.pollInterval = 0.05
        runs.workStatusFetcher = { id in
            polls.add(id)
            await gate.wait()
            return try JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(#"{"status":"running"}"#.utf8))
        }
        // Each window's setup used to resume following: two windows, two followers.
        runs.resumeFollowing(store: store)
        runs.resumeFollowing(store: store)
        let end = Date().addingTimeInterval(3)
        while polls.values.isEmpty, Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(polls.values == ["w-1"], "one follower per run, not one per window")
        run.phase = .canceled
        await gate.open()
    }

    @Test func hidingThePreviewEndsFullWindow() {
        let router = AppRouter()
        router.showPreview = true
        router.previewFullScreen = true
        router.showPreview = false
        #expect(!router.previewFullScreen, "the sidebar and its toggle come back")
    }

    @Test func leavingTheBotEndsFullWindow() {
        let router = AppRouter()
        router.usesSidebar = true
        let a = UUID(), b = UUID()
        router.sidebar = .bot(a)
        router.showPreview = true
        router.previewFullScreen = true
        router.sidebar = .bot(b)
        #expect(!router.previewFullScreen, "another bot never opens in this bot's full-window preview")
        router.previewFullScreen = true
        router.path = [.bot(a)]
        #expect(!router.previewFullScreen)
    }

    @Test func somethingForYouEndsFullWindow() {
        let router = AppRouter()
        router.showPreview = true
        router.previewFullScreen = true
        router.attentionArrived()
        #expect(!router.previewFullScreen, "a reply or a card that needs you is seen in the chat")
        #expect(router.showPreview, "the preview stays beside the chat")
    }
}
