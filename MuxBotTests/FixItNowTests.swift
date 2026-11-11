import Foundation
import Testing
@testable import MuxBot

/// Fix it now is the approval: the bug card shows the model (the dispatch
/// card's own row) and one tap starts the run on it. The dispatch card is
/// left to decide only what needs you there.
@Suite(.serialized) @MainActor
struct FixItNowTests {
    private func setUp(paired: Bool = true) -> (BotStore, Bot, RunCoordinator, ChatMessage, BugDraft) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        if paired { keychain.items["darkmux.client.token"] = "t0ken" }
        let defaults = UserDefaults(suiteName: "muxbot-tests-fixnow-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        runs.pollInterval = 0.02
        let draft = BugDraft(title: "Footer overlaps", described: "x", page: "/", viewport: 820, facts: [], repo: nil)
        let card = store.append(.assistant, "{}", kind: .bugCard, to: store.conversation(for: .bot(bot.id)))
        return (store, bot, runs, card, draft)
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func oneTapStartsTheRunOnTheModelPickedOnTheBugCard() async {
        let (store, bot, runs, card, draft) = setUp()
        var submitted: String?
        runs.workSubmitter = { _, _, profile, _, _ in submitted = profile; return ("w-1", profile) }
        runs.workStatusFetcher = { _ in throw CancellationError() }
        let choice = ModelChoice(profile: "flint-managed", reason: "first in your Auto order that's running")
        let (run, _) = store.fixBug(card, draft: draft, bot: bot)
        #expect(runs.startNow(run, choice: choice, picked: "q38-27b-tf-managed", store: store))
        #expect(run.phase != .proposed, "no second Approve")
        await until { submitted != nil }
        #expect(submitted == "q38-27b-tf-managed")
    }

    @Test func aModelThatIsntRunningStaysOnTheCardToDecide() {
        let (store, bot, runs, card, draft) = setUp()
        var choice = ModelChoice(profile: "flint-managed", reason: "your default model")
        choice.unavailable = "flint-managed isn't running on this Mac."
        let (run, _) = store.fixBug(card, draft: draft, bot: bot)
        #expect(!runs.startNow(run, choice: choice, picked: nil, store: store))
        #expect(run.phase == .proposed)
        #expect(runs.runChoices[run.id]?.unavailable != nil, "the card says so")
    }

    @Test func unpairedStaysOnTheCard() {
        let (store, bot, runs, card, draft) = setUp(paired: false)
        let choice = ModelChoice(profile: "flint-managed", reason: "first in your Auto order that's running")
        let (run, _) = store.fixBug(card, draft: draft, bot: bot)
        #expect(!runs.startNow(run, choice: choice, picked: nil, store: store))
        #expect(run.phase == .proposed)
        #expect(runs.profile(for: run) == "flint-managed")
    }
}
