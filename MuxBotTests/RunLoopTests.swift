import Foundation
import SwiftData
import Testing
@testable import MuxBot

struct RunPhaseTests {
    @Test(arguments: [
        (RunPhase.proposed, RunEvent.approve, RunPhase.running),
        (.proposed, .cancel, .canceled),
        (.running, .finish(summary: "s"), .result),
        (.result, .keep, .kept),
        (.result, .tweak, .running),
        (.result, .discard, .discarded),
        (.kept, .openPR, .prOpened),
        (.kept, .skipPR, .done),
    ])
    func allowedTransitions(from: RunPhase, event: RunEvent, to: RunPhase) {
        #expect(from.next(on: event) == to)
    }

    @Test(arguments: [
        (RunPhase.proposed, RunEvent.keep),
        (.running, .keep),
        (.running, .tweak),
        (.result, .approve),
        (.discarded, .keep),
        (.prOpened, .openPR),
        (.canceled, .approve),
    ])
    func refusedTransitions(from: RunPhase, event: RunEvent) {
        #expect(from.next(on: event) == nil)
    }
}

@Suite(.serialized) @MainActor
struct RunLoopStoreTests {
    private func setUp() -> (BotStore, Bot) {
        let store = TestStore.fresh()
        return (store, store.add(name: "humancodereader", instructions: "Website"))
    }

    private func kinds(_ store: BotStore, _ bot: Bot) -> [MessageKind] {
        (store.conversation(for: .bot(bot.id)).messages ?? [])
            .sorted { $0.timestamp < $1.timestamp }
            .map(\.kind)
            .filter { $0 != .text }
    }

    @Test func fullLoopPostsOneCardPerStageAndTracksBotState() {
        let (store, bot) = setUp()
        let run = store.proposeRun(task: "Fix the footer", crew: .coder, on: bot)
        #expect(run.phase == .proposed)
        #expect(bot.state == .needsYou)

        #expect(store.apply(.approve, to: run))
        #expect(bot.state == .working)
        #expect(store.apply(.finish(summary: "Done"), to: run))
        #expect(bot.state == .needsYou)
        #expect(store.apply(.keep, to: run))
        #expect(store.apply(.openPR, to: run))
        #expect(run.phase == .prOpened)
        #expect(bot.state == .ready)
        #expect(kinds(store, bot) == [.dispatchCard, .runCard, .resultCard, .prCard])
    }

    @Test func tweakGoesBackToRunningOnTheSameRun() {
        let (store, bot) = setUp()
        let run = store.proposeRun(task: "Fix the footer", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        store.apply(.finish(summary: "First"), to: run)
        #expect(store.apply(.tweak, to: run))
        #expect(run.phase == .running)
        #expect(run.tweaks == 1)
        store.apply(.finish(summary: "Second"), to: run)
        #expect(run.summary == "Second")
        #expect(kinds(store, bot) == [.dispatchCard, .runCard, .resultCard, .runCard, .resultCard])
        #expect((bot.runs ?? []).count == 1)
    }

    @Test func discardClosesTheRunAndFreesTheBot() {
        let (store, bot) = setUp()
        let run = store.proposeRun(task: "x", crew: .reviewer, on: bot)
        store.apply(.approve, to: run)
        store.apply(.finish(summary: "s"), to: run)
        #expect(store.apply(.discard, to: run))
        #expect(run.phase == .discarded)
        #expect(bot.state == .ready)
    }

    @Test func refusedEventChangesNothing() {
        let (store, bot) = setUp()
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        let before = kinds(store, bot)
        #expect(!store.apply(.keep, to: run))
        #expect(run.phase == .proposed)
        #expect(kinds(store, bot) == before)
    }

    @Test func aDispatchTurnBecomesADispatchCardNotABarCard() async {
        let (store, bot) = setUp()
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        await brain.send("Fix the crash bugs in the footer", in: .bot(bot.id), store: store)
        #expect(!(store.conversation(for: .bot(bot.id)).messages ?? []).contains { $0.kind == .actionCard })
        #expect(bot.runs?.first?.crew == .coder)
        #expect(kinds(store, bot) == [.dispatchCard])
    }

    @Test func tweakWhenUnpairedSaysWhyAndLeavesTheResult() {
        let (store, bot) = setUp()
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        store.apply(.finish(summary: "s"), to: run)
        brain.tweakRunId = run.id
        brain.tweak("make it bigger", run: run, store: store)
        #expect(brain.tweakRunId == nil)
        #expect(run.phase == .result)
        #expect(run.tweaks == 0)
    }

}

@Suite(.serialized) @MainActor
struct StopRunTests {
    @Test func stoppingARunningRunCancelsItAndSaysSo() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        await BotBrain().stop(run, store: store)
        #expect(run.phase == .canceled)
        #expect(bot.state == .ready)
        #expect((store.conversation(for: .bot(bot.id)).messages ?? []).contains { $0.content == "Stopped." })
    }

    @Test func stopOnlyAppliesToRunningRuns() {
        #expect(RunPhase.running.next(on: .stop) == .canceled)
        #expect(RunPhase.result.next(on: .stop) == nil)
        #expect(RunPhase.proposed.next(on: .stop) == nil)
    }
}
