import Foundation
import Testing
@testable import MuxBot

/// The banner's × hides what needs you everywhere on this Mac (the sidebar
/// badge, Activity's Needs you, the menu bar and Dock counts) until
/// something new needs you. The run itself is untouched (Kain, 2026-11-07:
/// "even X out the warning at the top of the chat. the icon still remains").
@Suite(.serialized) @MainActor
struct NeedsYouDismissalTests {
    /// hcr as it was: a Fix #10 result that changed nothing (a question).
    private func setUp() -> (BotStore, Bot, BotRun, LocalBotState) {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        let run = store.proposeRun(task: "Fix #10: Tablet sizing looks off (kstrat2001/hcr)", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        store.apply(.finish(summary: "Changed nothing."), to: run)
        store.refreshState(of: bot)
        return (store, bot, run, LocalBotState(fileURL: nil))
    }

    @Test func hidingTheBannerClearsTheSidebarBadgeAndCounts() {
        let (_, bot, run, local) = setUp()
        #expect(bot.state == .needsYou)
        #expect(NeedsYou.shownState(bot, in: local) == .needsYou)
        NeedsYou.dismiss([run], in: local)
        #expect(NeedsYou.shownState(bot, in: local) == .ready, "the sidebar triangle goes")
        #expect(!NeedsYou.waiting(bot.runs ?? [], in: local).contains { $0.id == run.id }, "Activity, menu bar and Dock counts")
        #expect(NeedsYou.banner(bot.runs ?? [], in: local).isEmpty)
        #expect(run.phase == .result, "the run itself is untouched")
        #expect(bot.state == .needsYou, "nor the synced state")
    }

    @Test func somethingNewNeedsYouAgain() {
        let (store, bot, run, local) = setUp()
        NeedsYou.dismiss([run], in: local)
        let next = store.proposeRun(task: "Fix #11", crew: .coder, on: bot)
        store.refreshState(of: bot)
        #expect(NeedsYou.shownState(bot, in: local) == .needsYou)
        #expect(NeedsYou.banner(bot.runs ?? [], in: local).map(\.id) == [next.id])
    }

    @Test func aHiddenItemStaysHiddenAfterARelaunch() throws {
        let (_, bot, run, _) = setUp()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dismiss-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        NeedsYou.dismiss([run], in: LocalBotState(fileURL: file))
        #expect(NeedsYou.shownState(bot, in: LocalBotState(fileURL: file)) == .ready)
    }

    @Test func aBotStillRunningShowsWorkingOnceTheQuestionIsHidden() {
        let (store, bot, run, local) = setUp()
        let other = store.proposeRun(task: "Review", crew: .reviewer, on: bot)
        store.apply(.approve, to: other)
        NeedsYou.dismiss([run], in: local)
        #expect(NeedsYou.shownState(bot, in: local) == .working)
    }

    @Test func activitysNeedsYouLeavesOutHiddenItems() {
        let (_, bot, run, local) = setUp()
        NeedsYou.dismiss([run], in: local)
        let sections = ActivitySections(runs: bot.runs ?? [], isWaiting: { NeedsYou.isWaiting($0, in: local) })
        #expect(sections.needsYou.isEmpty)
        #expect(sections.finished.contains { $0.id == run.id }, "still listed, as finished")
    }
}
