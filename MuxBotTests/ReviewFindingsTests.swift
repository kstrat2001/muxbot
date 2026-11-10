import Foundation
import Testing
@testable import MuxBot

/// Fixes from the code review of 2026-11-10: the run loop.
@Suite(.serialized) @MainActor
struct ReviewFindingsRunTests {
    private func setUp() -> (BotStore, Bot, RunCoordinator) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-findings-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        runs.pollInterval = 0.02
        runs.profileSource = { [] }
        runs.deviceRuns = true
        runs.useOnDeviceModel = false
        return (store, bot, runs)
    }

    private func status(_ json: String) -> DarkmuxClient.WorkStatus {
        try! JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(json.utf8))
    }

    private func said(_ store: BotStore, _ bot: Bot) -> [String] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }.map(\.content)
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func running(_ store: BotStore, _ bot: Bot, _ runs: RunCoordinator, workId: String) -> BotRun {
        let run = store.proposeRun(task: "Make it warm", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        run.darkmuxWorkId = workId
        runs.markStartedHere(run)
        runs.recordWork(workId, for: run)
        return run
    }

    // 1: "Waiting for a free slot" is said once, however often darkmux
    // refuses the retry.

    @Test func waitingForASlotIsSaidOnce() async {
        let (store, bot, runs) = setUp()
        runs.queueRetryInterval = .milliseconds(20)
        let calls = Recorder()
        runs.workSubmitter = { _, _, _, _, _ in
            calls.add("submit")
            if calls.values.count < 5 { throw DarkmuxClient.ClientError(message: "too many", status: 429) }
            return ("w-9", nil)
        }
        runs.workStatusFetcher = { [self] _ in status(#"{"status":"running"}"#) }
        let run = store.proposeRun(task: "third", crew: .coder, on: bot)
        runs.decide(.approve, on: run, store: store)
        await until { run.darkmuxWorkId == "w-9" }
        #expect(run.darkmuxWorkId == "w-9")
        #expect(calls.values.count == 5, "refused four times, then accepted")
        #expect(said(store, bot).filter { $0 == RunCoordinator.waitingForSlot }.count == 1, "\(said(store, bot))")
        run.phase = .canceled
    }

    @Test func aRefusedRetryKeepsItsPlaceInLine() async {
        let (store, bot, runs) = setUp()
        runs.queueRetryInterval = .seconds(60)
        let order = Recorder()
        let open = Counter()
        runs.workSubmitter = { _, message, _, _, _ in
            let task = message.hasPrefix("first") ? "first" : "second"
            order.add(task)
            if open.count == 0 { throw DarkmuxClient.ClientError(message: "too many", status: 429) }
            return ("w-\(task)", nil)
        }
        runs.workStatusFetcher = { [self] _ in status(#"{"status":"running"}"#) }
        let first = store.proposeRun(task: "first", crew: .coder, on: bot)
        runs.decide(.approve, on: first, store: store)
        await until { order.values.count == 1 }
        let other = store.add(name: "other", instructions: "")
        other.workspaceName = "other-1"
        let second = store.proposeRun(task: "second", crew: .coder, on: other)
        runs.decide(.approve, on: second, store: store)
        await until { order.values.count == 2 }
        // A retry darkmux refuses again: "first" stays ahead of "second".
        runs.slotFreed(store: store)
        await until { order.values.count == 3 }
        try? await Task.sleep(for: .milliseconds(50))
        open.add()
        runs.slotFreed(store: store)
        await until { order.values.count == 4 }
        #expect(order.values == ["first", "second", "first", "first"], "\(order.values)")
        first.phase = .canceled
        second.phase = .canceled
    }
}
