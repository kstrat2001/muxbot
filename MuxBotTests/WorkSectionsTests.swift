import Foundation
import Testing
@testable import MuxBot

@Suite(.serialized) @MainActor
struct WorkSectionsTests {
    private func run(_ store: BotStore, _ bot: Bot, _ task: String, to phase: RunPhase, minutesAgo: Double) -> BotRun {
        let r = store.proposeRun(task: task, crew: .coder, on: bot)
        r.createdAt = Date().addingTimeInterval(-minutesAgo * 60)
        r.phase = phase
        return r
    }

    @Test func groupsNeedsYouThenRunningThenFinished() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        let done = run(store, bot, "old fix", to: .done, minutesAgo: 30)
        let stopped = run(store, bot, "stopped one", to: .canceled, minutesAgo: 20)
        let running = run(store, bot, "fixing now", to: .running, minutesAgo: 2)
        let result = run(store, bot, "waiting for keep", to: .result, minutesAgo: 5)
        let proposed = run(store, bot, "waiting for approve", to: .proposed, minutesAgo: 1)

        let s = WorkSections(runs: [done, stopped, running, result, proposed])
        #expect(s.needsYou.map(\.task) == ["waiting for approve", "waiting for keep"])
        #expect(s.running.map(\.task) == ["fixing now"])
        #expect(s.finished.map(\.task) == ["stopped one", "old fix"])
        #expect(!s.isEmpty)
    }

    @Test func finishedKeepsOnlyTheRecentOnes() {
        let store = TestStore.fresh()
        let bot = store.add(name: "b", instructions: "", modelName: "")
        let runs = (0..<30).map { run(store, bot, "t\($0)", to: .done, minutesAgo: Double($0)) }
        #expect(WorkSections(runs: runs).finished.count == 20)
    }

    @Test func noRunsIsEmpty() {
        #expect(WorkSections(runs: []).isEmpty)
    }
}
