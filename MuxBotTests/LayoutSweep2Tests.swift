import Foundation
import Testing
@testable import MuxBot

/// Sweep 2, layout.
@Suite(.serialized) @MainActor
struct LayoutSweep2Tests {
    // 1: "Another Mac" only for a run that started somewhere else.

    @Test func aRunThatNeverStartedHasNoMachine() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let proposed = store.proposeRun(task: "x", crew: .coder, on: bot)
        #expect(ActivityRow.machine(for: proposed) == "")
        store.apply(.cancel, to: proposed)
        #expect(ActivityRow.machine(for: proposed) == "", "canceled before Approve")
        let elsewhere = store.proposeRun(task: "y", crew: .coder, on: bot)
        store.apply(.approve, to: elsewhere)
        #expect(ActivityRow.machine(for: elsewhere) == "Another Mac")
    }

    // 2: going wide from Activity stays on Activity; no bots keeps Start.

    @Test func goingWideFromActivityStaysOnActivity() {
        let router = AppRouter()
        router.tab = .activity
        router.path = [.bot(UUID())]
        router.layoutChanged(toSidebar: true, botCount: 1)
        #expect(router.sidebar == .activity)
    }

    @Test func goingWideWithNoBotsKeepsTheStartChooser() {
        let router = AppRouter()
        router.layoutChanged(toSidebar: true, botCount: 0)
        #expect(router.sidebar == nil, "the chooser shows when nothing is selected")
        let some = AppRouter()
        some.layoutChanged(toSidebar: true, botCount: 2)
        #expect(some.sidebar == .lead)
    }
}
