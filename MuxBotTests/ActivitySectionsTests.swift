import Foundation
import Testing
@testable import MuxBot

@Suite(.serialized) @MainActor
struct ActivitySectionsTests {
    private func run(_ store: BotStore, _ bot: Bot, _ task: String, to phase: RunPhase, minutesAgo: Double) -> BotRun {
        let r = store.proposeRun(task: task, crew: .coder, on: bot)
        r.createdAt = Date().addingTimeInterval(-minutesAgo * 60)
        r.phase = phase
        return r
    }

    @Test func groupsNeedsYouThenRunningThenFinished() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        let done = run(store, bot, "old fix", to: .done, minutesAgo: 30)
        let stopped = run(store, bot, "stopped one", to: .canceled, minutesAgo: 20)
        let running = run(store, bot, "fixing now", to: .running, minutesAgo: 2)
        let result = run(store, bot, "waiting for keep", to: .result, minutesAgo: 5)
        let proposed = run(store, bot, "waiting for approve", to: .proposed, minutesAgo: 1)

        let s = ActivitySections(runs: [done, stopped, running, result, proposed])
        #expect(s.needsYou.map(\.task) == ["waiting for approve", "waiting for keep"])
        #expect(s.running.map(\.task) == ["fixing now"])
        #expect(s.finished.map(\.task) == ["stopped one", "old fix"])
        #expect(!s.isEmpty)
    }

    @Test func finishedKeepsOnlyTheRecentOnes() {
        let store = TestStore.fresh()
        let bot = store.add(name: "b", instructions: "")
        let runs = (0..<30).map { run(store, bot, "t\($0)", to: .done, minutesAgo: Double($0)) }
        #expect(ActivitySections(runs: runs).finished.count == 20)
    }

    @Test func noRunsIsEmpty() {
        #expect(ActivitySections(runs: []).isEmpty)
    }
}

struct ActivityTimeTextTests {
    let now = Date(timeIntervalSince1970: 1_794_000_000)   // fixed clock

    @Test func startedIsRelativeToday() {
        #expect(ActivityTime.started(now.addingTimeInterval(-5 * 60), now: now, calendar: .init(identifier: .gregorian)) == "5 min ago")
        #expect(ActivityTime.started(now.addingTimeInterval(-20), now: now, calendar: .init(identifier: .gregorian)) == "just now")
    }

    @Test func startedOnEarlierDaysShowsTheDate() {
        let text = ActivityTime.started(now.addingTimeInterval(-3 * 86_400), now: now, calendar: .init(identifier: .gregorian))
        #expect(!text.contains("ago"))
        #expect(text.count > 5)
    }

    @Test func durations() {
        #expect(ActivityTime.duration(seconds: 42) == "0:42")
        #expect(ActivityTime.duration(seconds: 3 * 60 + 5) == "3:05")
        #expect(ActivityTime.duration(seconds: 2 * 3600 + 7 * 60) == "2h 7m")
    }
}

@Suite(.serialized) @MainActor
struct WorkSortTests {
    @Test func statusRankPutsNeedsYouThenRunningThenFinished() {
        let store = TestStore.fresh()
        let bot = store.add(name: "b", instructions: "")
        let a = store.proposeRun(task: "a", crew: .coder, on: bot); a.phase = .done
        let b = store.proposeRun(task: "b", crew: .coder, on: bot); b.phase = .running
        let c = store.proposeRun(task: "c", crew: .coder, on: bot); c.phase = .result
        #expect([a, b, c].sorted { $0.statusRank < $1.statusRank }.map(\.task) == ["c", "b", "a"])
    }

    @Test func approveAndFinishStampTheRunsTimes() {
        let store = TestStore.fresh()
        let bot = store.add(name: "b", instructions: "")
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        #expect(run.startedAt == nil)
        store.apply(.approve, to: run)
        #expect(run.startedAt != nil)
        store.apply(.finish(summary: "s"), to: run)
        #expect(run.finishedAt != nil)
        #expect(run.durationSeconds != nil)
    }
}
