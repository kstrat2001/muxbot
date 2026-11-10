import Foundation
import SwiftData
import Testing
@testable import MuxBot

/// Each finished run is committed by darkmux; the result reads as the bot's
/// reply with one Undo, and your reply continues the run.
@Suite(.serialized) @MainActor
struct AutoCommitFlowTests {
    private func setUp() -> (BotStore, Bot) {
        let store = TestStore.fresh()
        return (store, store.add(name: "hcr", instructions: "Site"))
    }

    private func finished(_ store: BotStore, _ bot: Bot, changed: [String], task: String = "Fix #8") -> BotRun {
        let run = store.proposeRun(task: task, crew: .coder, on: bot)
        store.apply(.approve, to: run)
        run.darkmuxWorkId = "w-\(UUID().uuidString.prefix(8))"
        run.changedFiles = changed
        // darkmux commits every finished run that changed files.
        if !changed.isEmpty { run.keptCommit = "c0ffee1"; run.keptBranch = "mux/hcr" }
        store.apply(.finish(summary: "Done."), to: run)
        return run
    }

    @Test func darkmuxsCommitIsRead() throws {
        let json = #"{"status":"done","result":{"final_assistant":"ok"},"changes":{"files":[{"path":"a.txt","added":1,"removed":0}]},"commit":"abc1234","branch":"mux/hcr-1","commit_error":null,"undone":false}"#
        let s = try JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(json.utf8))
        #expect(s.commit == "abc1234")
        #expect(s.branch == "mux/hcr-1")
        #expect(s.commitError == nil)
    }

    @Test func onlyApprovalsAndQuestionsNeedYou() {
        let (store, bot) = setUp()
        let proposed = store.proposeRun(task: "a", crew: .coder, on: bot)
        let committed = finished(store, bot, changed: ["a.txt +1 −0"])
        let question = finished(store, bot, changed: [])
        let running = store.proposeRun(task: "r", crew: .coder, on: bot)
        store.apply(.approve, to: running)
        #expect(proposed.needsYou)
        #expect(question.needsYou)
        #expect(!committed.needsYou, "a committed result is done, not waiting")
        #expect(!running.needsYou)
        #expect(RunNotice.badgeCount([proposed, committed, question, running]) == 2)
        store.refreshState(of: bot)
        #expect(bot.state == .needsYou)
    }

    @Test func aReplyAfterAResultContinuesThatRun() async {
        let (store, bot) = setUp()
        let run = finished(store, bot, changed: ["a.txt +1 −0"])
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.runs.deviceRuns = true
        await brain.send("make the gutter a bit wider", in: .bot(bot.id), store: store)
        let thread = store.conversation(for: .bot(bot.id)).messages ?? []
        #expect(thread.contains { $0.content == "Can't run this yet: this app isn't paired with darkmux." }, "sent as a Tweak of \(run.task)")
        #expect(!thread.contains { $0.kind == .actionCard })
        #expect(bot.runs?.count == 1)
    }

    @Test func anUndoneResultCollapses() {
        let (store, bot) = setUp()
        let run = finished(store, bot, changed: ["a.txt +1 −0"])
        #expect(RunCardState.collapsedLine(run) == nil)
        store.apply(.discard, to: run)
        #expect(RunCardState.collapsedLine(run) == "Undone")
    }

    @Test func onlyAWorkingRunBlocksANewOne() {
        let (store, bot) = setUp()
        bot.workspaceName = "site"
        _ = finished(store, bot, changed: ["a.txt +1 −0"])
        let next = store.proposeRun(task: "next", crew: .coder, on: bot)
        #expect(RunBlocker.check(paired: true, crew: .coder, bot: bot, deviceRuns: true, excluding: next.id) == nil,
                "a committed result blocks nothing")
        let working = store.proposeRun(task: "w", crew: .coder, on: bot)
        store.apply(.approve, to: working)
        RunCoordinator().markStartedHere(working)   // this Mac's run blocks; another Mac's wouldn't
        #expect(RunBlocker.check(paired: true, crew: .coder, bot: bot, deviceRuns: true, excluding: next.id) == .runWorking(working.id))
    }

    @Test func anUndoRefusalNamesTheLaterRunByItsTask() {
        let (store, bot) = setUp()
        let later = finished(store, bot, changed: ["a.txt +1 −0"], task: "Fix #12: footer")
        later.darkmuxWorkId = "w-later1"
        let text = RunResultText.undoRefusal("run w-later1 changed the same files later; undo that first", runs: [later])
        // Plain words (sweep 9 #1): darkmux's own text is behind Show details.
        #expect(text == "“Fix #12: footer” changed the same files later. Undo that run first.")
        #expect(RunResultText.undoRefusal("already undone", runs: []) == "darkmux couldn't undo it. Show details has what it reported.")
    }

    @Test func theBannerPinsApprovalsAndQuestionsUntilDismissed() {
        let (store, bot) = setUp()
        let proposed = store.proposeRun(task: "a", crew: .coder, on: bot)
        let question = finished(store, bot, changed: [], task: "b")
        _ = finished(store, bot, changed: ["c.txt +1 −0"], task: "c")
        let local = LocalBotState(fileURL: nil)
        #expect(Set(NeedsYou.banner(bot.runs ?? [], in: local).map(\.id)) == [proposed.id, question.id])
        NeedsYou.dismiss([proposed, question], in: local)
        #expect(NeedsYou.banner(bot.runs ?? [], in: local).isEmpty)
        let fresh = store.proposeRun(task: "d", crew: .coder, on: bot)
        #expect(NeedsYou.banner(bot.runs ?? [], in: local).map(\.id) == [fresh.id], "a new item brings it back")
    }

    @Test func aSmallTabletPresetChecks768Breakpoints() {
        #expect(PreviewViewport.smallTablet.width == 768)
    }
}
