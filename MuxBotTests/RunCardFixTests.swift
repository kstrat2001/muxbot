import Foundation
import SwiftData
import Testing
@testable import MuxBot

struct AgentQuestionTests {
    @Test func numberedOptionsBecomeAnswers() {
        let notes = """
            I didn't change anything yet. Which tablet breakpoint should I use?

            1. Treat 820px as tablet and switch to the mobile nav below 900px
            2) Keep the desktop nav and tighten spacing between 768 and 1024px
            **3.** Leave it as is
            """
        #expect(AgentQuestion.options(in: notes) == [
            "Treat 820px as tablet and switch to the mobile nav below 900px",
            "Keep the desktop nav and tighten spacing between 768 and 1024px",
            "Leave it as is",
        ])
        #expect(AgentQuestion.options(in: "Changed pricing.tsx. Done.").isEmpty)
    }
}

@Suite(.serialized) @MainActor
struct NoChangeResultTests {
    private func finished(changed: [String]) -> (BotStore, Bot, BotRun, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        let run = store.proposeRun(task: "Fix #10: Tablet sizing", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        run.darkmuxWorkId = "w-477d9594ce0b5bb4"
        run.changedFiles = changed
        // darkmux commits every finished run that changed files.
        if !changed.isEmpty { run.keptCommit = "c0ffee1"; run.keptBranch = "mux/hcr" }
        store.apply(.finish(summary: "I have a question."), to: run)
        let brain = BotBrain()
        brain.runs.deviceRuns = true
        brain.runs.markStartedHere(run)   // this Mac's run (sweep batch 2)
        return (store, bot, run, brain)
    }

    @Test func aNoChangeRunClosesWithoutDarkmux() async throws {
        let (store, _, run, brain) = finished(changed: [])
        brain.runs.decide(.discard, on: run, store: store)
        try await Task.sleep(for: .milliseconds(50))
        #expect(run.phase == .discarded, "nothing to undo, so it closes here")
        #expect(brain.runs.decisionErrors[run.id] == nil)
    }

    @Test func aNoChangeRunCantBeKept() async throws {
        let (store, _, run, brain) = finished(changed: [])
        brain.runs.decide(.keep, on: run, store: store)
        try await Task.sleep(for: .milliseconds(50))
        #expect(run.phase == .result)
        #expect(brain.runs.decisionErrors[run.id] == "Nothing changed, so there's nothing to keep.")
    }

    @Test func aFailedUndoSaysWhyOnTheCard() async throws {
        let (store, _, run, brain) = finished(changed: ["a.txt +1 −0"])
        brain.runs.decide(.discard, on: run, store: store)   // unpaired: can't reach darkmux
        try await Task.sleep(for: .milliseconds(50))
        #expect(run.phase == .result)
        #expect(brain.runs.decisionErrors[run.id] == "Can't do that yet: this app isn't paired with darkmux.")
    }

    @Test func aResultALaterRunReplacedCollapses() {
        let (store, bot, run, _) = finished(changed: [])
        #expect(!RunCardState.isReplaced(run))
        let next = store.proposeRun(task: "Fix #10 again", crew: .coder, on: bot)
        next.createdAt = run.createdAt.addingTimeInterval(5)
        #expect(RunCardState.isReplaced(run))
    }

}

@Suite(.serialized) @MainActor
struct FollowUpRoutingTests {
    @Test func kainsFollowUpContinuesTheRunInsteadOfAStalePR() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "The humancodereader.com website.")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        let thread = store.conversation(for: .bot(bot.id))
        store.append(.assistant, "Committed to mux/x. PR #9 is open for #8.", to: thread)
        let run = store.proposeRun(task: "Fix #10: Tablet sizing looks off (kstrat2001/hcr)", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        run.darkmuxWorkId = "w-1"
        store.apply(.finish(summary: "Which breakpoint?"), to: run)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.runs.deviceRuns = true
        await brain.send("i'm not seeing it fixed in the live viewer", in: .bot(bot.id), store: store)
        // Your reply continues the run (a Tweak); unpaired here, so it says why it can't send yet.
        #expect((thread.messages ?? []).contains { $0.content == "Can't run this yet: this app isn't paired with darkmux." })
        #expect(!(thread.messages ?? []).contains { $0.kind == .actionCard })
        #expect(bot.runs?.count == 1, "never a new dispatch, never a stale PR")
    }

    @Test func aFollowUpAfterAStoppedRunAsksBeforeRunningAgain() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        let run = store.proposeRun(task: "Fix #10", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        store.apply(.stop, to: run)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        await brain.send("try the footer too", in: .bot(bot.id), store: store)
        let card = (store.conversation(for: .bot(bot.id)).messages ?? []).first { $0.kind == .actionCard }
        guard case let .tweak(runId, _)? = card?.action else { Issue.record("expected an Approve card"); return }
        #expect(runId == run.id)
    }

    @Test func aBareFixPRNumberNeverBecomesADispatchCard() {
        #expect(BotBrain.isBareReference("Fix PR #9"))
        #expect(BotBrain.isBareReference("fix #8"))
        #expect(BotBrain.isBareReference("Review #12."))
        #expect(!BotBrain.isBareReference("Fix #8: No padding on the pricing page (kstrat2001/hcr)"))
        #expect(!BotBrain.isBareReference("Make the footer links blue"))
    }

    @Test func aTweakTellsDarkmuxWhichRunItContinues() throws {
        let body = DarkmuxClient.WorkBody(role: "coder", message: "m", profile: nil, workspace: "site", continues: "w-1")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: String]
        #expect(json?["continues"] == "w-1")
    }
}
