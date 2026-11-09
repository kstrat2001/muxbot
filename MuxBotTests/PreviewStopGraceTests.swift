import Foundation
import Testing
@testable import MuxBot

/// A clock the test moves: every sleep waits until `fire()`.
@MainActor
final class ManualSleeper {
    private(set) var requested: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Ends every sleep waiting now.
    func fire() {
        let now = waiting
        waiting = []
        now.forEach { $0.resume() }
    }

    /// Lets scheduled tasks reach their sleep.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// Leaving a bot's thread stops its preview only after a grace period, so
/// coming straight back (or SwiftUI rebuilding the view) never sends darkmux
/// a stop and then a new start. Quitting still stops at once.
@Suite(.serialized) @MainActor
struct PreviewStopGraceTests {
    private func setUp() -> (Bot, RunCoordinator, ManualSleeper, Recorder, Recorder) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-grace-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        let starts = Recorder()
        runs.previewFetcher = { start in
            if start { starts.add("start") }
            return LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:5000/")!)
        }
        let stops = Recorder()
        runs.previewStopper = { stops.add($0) }
        let clock = ManualSleeper()
        runs.previewGraceSleep = { await clock.sleep($0) }
        return (bot, runs, clock, starts, stops)
    }

    @Test func leavingStopsThePreviewOnlyAfterThirtySeconds() async {
        let (bot, runs, clock, _, stops) = setUp()
        await runs.ensurePreview(for: bot)
        runs.leavePreview(for: bot)
        await clock.settle()
        #expect(clock.requested == [.seconds(30)])
        #expect(stops.values.isEmpty, "nothing is stopped while the grace runs")
        #expect(runs.livePreviews[bot.id]?.status == .ready)
        clock.fire()
        await clock.settle()
        #expect(stops.values == ["site-1"])
        #expect(runs.livePreviews[bot.id]?.status == .stopped)
    }

    @Test func comingBackWithinTheGraceSendsNoStopAndNoNewStart() async {
        let (bot, runs, clock, starts, stops) = setUp()
        await runs.ensurePreview(for: bot)
        runs.leavePreview(for: bot)
        await clock.settle()
        runs.returnToPreview(for: bot)
        await runs.ensurePreview(for: bot)
        clock.fire()
        await clock.settle()
        #expect(stops.values.isEmpty)
        #expect(starts.values == ["start"], "only the first start")
        #expect(runs.livePreviews[bot.id]?.status == .ready)
    }

    @Test func openingThePreviewAgainAlsoCancelsTheStop() async {
        let (bot, runs, clock, starts, stops) = setUp()
        await runs.ensurePreview(for: bot)
        runs.leavePreview(for: bot)
        await clock.settle()
        await runs.ensurePreview(for: bot)
        clock.fire()
        await clock.settle()
        #expect(stops.values.isEmpty)
        #expect(starts.values == ["start"])
    }

    @Test func quittingStopsAtOnceEvenDuringTheGrace() async {
        let (bot, runs, clock, _, stops) = setUp()
        await runs.ensurePreview(for: bot)
        runs.leavePreview(for: bot)
        await clock.settle()
        await runs.stopAllPreviews()
        #expect(stops.values == ["site-1"], "stopped without waiting for the grace")
        clock.fire()
        await clock.settle()
        #expect(stops.values == ["site-1"], "and never a second stop")
    }

    @Test func theStopButtonIsImmediate() async {
        let (bot, runs, clock, _, stops) = setUp()
        await runs.ensurePreview(for: bot)
        runs.leavePreview(for: bot)
        await clock.settle()
        await runs.stopPreview(for: bot)
        #expect(stops.values == ["site-1"])
        clock.fire()
        await clock.settle()
        #expect(stops.values == ["site-1"])
    }

    @Test func leavingTwiceSchedulesOneStop() async {
        let (bot, runs, clock, _, stops) = setUp()
        await runs.ensurePreview(for: bot)
        runs.leavePreview(for: bot)
        runs.leavePreview(for: bot)
        await clock.settle()
        clock.fire()
        await clock.settle()
        #expect(stops.values == ["site-1"])
    }
}
