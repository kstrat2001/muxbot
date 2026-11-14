import Foundation
import Testing
@testable import MuxBot

/// Sweep batch 2: a run says what really happened. Stopped only when you
/// (or darkmux, on request) stopped it; failures say why in plain words;
/// another Mac's runs are left alone; a revoked pairing is noticed.
@Suite(.serialized) @MainActor
struct RunsSayWhatHappenedTests {
    private func setUp(paired: Bool = true) -> (BotStore, Bot, RunCoordinator) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        if paired { keychain.items["darkmux.client.token"] = "t0ken" }
        let defaults = UserDefaults(suiteName: "muxbot-tests-runs-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        runs.pollInterval = 0.02
        return (store, bot, runs)
    }

    private func running(_ store: BotStore, _ bot: Bot, _ runs: RunCoordinator, workId: String? = "w-1", here: Bool = true) -> BotRun {
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        run.phase = .running
        run.darkmuxWorkId = workId
        if here { runs.markStartedHere(run) }
        return run
    }

    /// Kain, 2026-11-14: LM Studio's server was off, the dispatch failed in
    /// 5 seconds, and darkmux still said "done": the card said "Changed
    /// nothing." A failed envelope is a failure that says why.
    @Test func aDispatchThatNeverReachedTheModelIsAFailure() {
        let s = status(#"{"status":"done","result":{"result":"error","error":"streaming request transport failure: http://localhost:1234/v1/chat/completions: Connection refused (os error 61)"},"changes":{"files":[]}}"#)
        #expect(s.status == "error")
        let why = RunResultText.failure(code: s.code, error: s.error ?? "", reason: s.reason)
        #expect(why.contains("isn't answering"), "\(why)")
        #expect(status(#"{"status":"done","result":{"result":"stop","final_assistant":"ok"}}"#).status == "done")
        // With a code darkmux gives, a refused connection still says so.
        #expect(RunResultText.failure(code: "dispatch_failed", error: "Connect error: Connection refused (os error 61)", reason: nil).contains("isn't answering"))
        // Never "see Show details" as the whole answer.
        #expect(!RunResultText.failure(code: nil, error: "dispatch exited 1", reason: nil).contains("Show details"))
    }

    /// Kain, 2026-11-14: "the app isn't checking at all?" and "shouldn't
    /// the darkmux command be used to see what's loaded?" darkmux says when
    /// LM Studio's local server is off (darkmux #3578): the card says so
    /// before Approve and nothing is sent; darkmux listing it again as able
    /// to run clears it. The app never probes the engine itself.
    @Test func aModelWhoseServerIsOffIsCaughtBeforeApprove() async {
        let (store, bot, runs) = setUp()
        let run = store.proposeRun(task: "remove this text", crew: .coder, on: bot)
        let off = DarkmuxClient.ProfileInfo(name: "qwen", model: "qwen3.6", endpoint: "lmstudio", reachable: false,
                                            availability: .init(state: "unavailable", reason: "LM Studio's local server is off, so a dispatch can't reach the model"))
        runs.lastListed = [off]
        runs.override(run, with: "qwen")
        #expect(runs.blocker(for: run) == .modelServerOff("LM Studio"))
        #expect(runs.whyRunCannotStart(run)?.contains("local server is off") == true)
        #expect(ModelLabel.whyNot(off)?.contains("local server is off") == true)
        runs.decide(.approve, on: run, store: store)
        #expect(run.phase == .proposed, "nothing is sent")
        var on = off
        on.reachable = true
        on.availability = .init(state: "resident", reason: nil)
        runs.profileSourceByRole = { _ in [on] }
        await runs.recheckModels(for: run)
        #expect(runs.blocker(for: run) == nil)
    }

    /// The setup check's LM Studio row comes from darkmux once paired.
    @Test func setupReadsLMStudioFromDarkmux() {
        let off = DarkmuxClient.ProfileInfo(name: "q", model: "q", endpoint: "lmstudio", reachable: false,
                                            availability: .init(state: "unavailable", reason: "LM Studio's local server is off"))
        let up = DarkmuxClient.ProfileInfo(name: "q", model: "q", endpoint: "lmstudio", reachable: true,
                                           availability: .init(state: "resident", reason: nil))
        let flint = DarkmuxClient.ProfileInfo(name: "f", model: "f", endpoint: "flint", reachable: true)
        #expect(SetupProbe.lmStudio(in: [off, flint]) == .notAnswering)
        #expect(SetupProbe.lmStudio(in: [up, flint]) == .models(1))
        #expect(SetupProbe.lmStudio(in: [flint]) == nil)
    }

    @Test func nothingChangedAndNothingSaidSaysWhatToTry() {
        let line = RunResultText.fallbackSummary(report: "", files: [])
        #expect(line.hasPrefix("Changed nothing"))
        #expect(line.contains("another model"))
    }

    private func status(_ json: String) -> DarkmuxClient.WorkStatus {
        try! JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(json.utf8))
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func said(_ store: BotStore, _ bot: Bot) -> [String] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }.map(\.content)
    }

    // 1. "Stopped." only when it was stopped.

    @Test func aRunDarkmuxForgotFailsPlainlyInsteadOfStopping() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs)
        runs.workStatusFetcher = { _ in throw DarkmuxClient.ClientError(message: "no such work", status: 404) }
        runs.resumeFollowing(store: store)
        await until { run.phase != .running }
        #expect(run.phase == .failed)
        #expect(run.summary.contains(RunResultText.lostTrack), "\(run.summary)")
        #expect(!said(store, bot).contains("Stopped."))
    }

    @Test func anErrorThatMentionsKilledIsAFailureNotAStop() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs)
        runs.workStatusFetcher = { [self] _ in status(#"{"status":"error","error":"model server killed (signal 9)","reason":"failed","code":"model_start_failed"}"#) }
        runs.resumeFollowing(store: store)
        await until { run.phase != .running }
        #expect(run.phase == .failed)
        #expect(run.summary.contains("The model wouldn't start"), "\(run.summary)")
        _ = bot
    }

    @Test func cancelledIsTheOnlyStop() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs)
        runs.workStatusFetcher = { [self] _ in status(#"{"status":"cancelled","reason":"cancelled"}"#) }
        runs.resumeFollowing(store: store)
        await until { run.phase != .running }
        #expect(run.phase == .canceled)
        _ = bot
    }

    @Test(arguments: [("busy", "busy"), ("wont_fit", "doesn't fit"), ("engine_unavailable", "isn't running"), ("port_in_use", "port")])
    func failuresAreWordedFromDarkmuxsCode(code: String, words: String) {
        let why = RunResultText.failure(code: code, error: "Error: something internal at /Users/x", reason: "failed")
        #expect(why.localizedCaseInsensitiveContains(words), "\(code): \(why)")
        #expect(!why.contains("/Users/"))
    }

    @Test func classifyNoLongerGuessesAStopFromWords() {
        #expect(RunResultText.classify(error: "the server got SIGTERM", reason: "failed") != .stopped)
    }

    // 2. Another Mac's runs.

    @Test func anotherMacsRunIsNotFollowedHere() async {
        let (store, bot, runs) = setUp()
        _ = running(store, bot, runs, here: true)
        let theirs = running(store, bot, runs, workId: "w-theirs", here: false)
        let polled = Recorder()
        runs.workStatusFetcher = { [self] id in polled.add(id); return status(#"{"status":"running"}"#) }
        runs.resumeFollowing(store: store)
        await until { !polled.values.isEmpty }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!polled.values.contains("w-theirs"), "darkmux here never knew it")
        #expect(theirs.phase == .running, "left as the other Mac reports it")
        for r in bot.runs ?? [] { r.phase = .canceled }
    }

    @Test func runsFromBeforeThisBuildAreAdoptedOnceIfFinished() {
        let (store, bot, runs) = setUp()
        // Adoption happens once per install (sweep 2 #7): this test's own.
        runs.adoptionDefaults = UserDefaults(suiteName: "muxbot-tests-adopt-\(UUID().uuidString)")!
        let done = store.proposeRun(task: "old result", crew: .coder, on: bot)
        done.phase = .result
        let inFlight = store.proposeRun(task: "old running", crew: .coder, on: bot)
        inFlight.phase = .running
        runs.adoptLegacyRuns(store: store)
        #expect(done.startedHere, "its Undo works on this Mac")
        #expect(!inFlight.startedHere, "whose darkmux has it can't be told")
    }

    // 3. Stop that can't reach darkmux.

    @Test func stopWithoutDarkmuxNeverMarksItStopped() async {
        let (store, bot, runs) = setUp(paired: false)
        let run = running(store, bot, runs)
        await runs.stop(run, store: store)
        #expect(run.phase == .running, "it's still running on darkmux")
        #expect(said(store, bot).last == RunCoordinator.stopUnpaired)
    }

    @Test func anotherMacsRunSaysWhereToStopIt() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs, here: false)
        await runs.stop(run, store: store)
        #expect(run.phase == .running)
        #expect(said(store, bot).last == RunCoordinator.stopElsewhere)
    }

    // 4. Approved, then the app quit before darkmux had it.

    @Test func aRunThatNeverReachedDarkmuxFailsOnResume() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs, workId: nil)
        runs.resumeFollowing(store: store)
        #expect(run.phase == .failed)
        #expect(run.summary.contains(RunResultText.quitBeforeStart))
        _ = bot
    }

    // 5. A revoked pairing.

    @Test func a401UnpairsWithAPlainSentence() async {
        let connection = FleetConnection(keychain: { let k = MemoryKeychain(); k.items["darkmux.client.token"] = "t0ken"; return k }(),
                                         defaults: UserDefaults(suiteName: "muxbot-tests-401-\(UUID().uuidString)")!)
        var shown = false
        connection.onRevoked = { shown = true }
        connection.revoked(token: "t0ken")
        #expect(connection.token == nil)
        #expect(connection.state == .failed(FleetConnection.revokedMessage))
        #expect(FleetConnection.revokedMessage == "darkmux no longer knows this app. Pair again.")
        #expect(shown, "pairing is shown")
    }

    @Test func theClientReportsA401() async throws {
        DarkmuxStub.status = 401
        var client = DarkmuxClient()
        client.session = DarkmuxStub.session
        let seen = Recorder()
        client.onUnauthorized = { seen.add($0) }
        _ = try? await client.workStatus(token: "old", workId: "w-1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(seen.values == ["old"], "with the token that was refused")
    }

    @Test func unpairedThePreviewAsksForPairingInsteadOfWaiting() async {
        let (_, bot, runs) = setUp(paired: false)
        await runs.ensurePreview(for: bot)
        #expect(runs.livePreviews[bot.id]?.status == .unavailable(.notPaired))
    }

    @Test func unpairedAWorkCopyIsNotAFailure() async {
        let (store, bot, runs) = setUp(paired: false)
        bot.workspaceName = nil
        store.addResource(.repo, "https://github.com/kstrat2001/site", to: bot)
        await runs.setUpWorkCopy(for: bot, store: store)
        #expect(runs.workCopySetup[bot.id] == nil, "nothing stale to show once paired")
    }

    // 6. Deleting a bot.

    @Test func deletingABotCancelsItsRunsFirst() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs)
        let cancelled = Recorder()
        runs.workCanceller = { cancelled.add($0) }
        runs.previewStopper = { cancelled.add("preview:\($0)") }
        runs.previewFetcher = { _ in LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:5000/")!) }
        await runs.ensurePreview(for: bot)
        let problem = await runs.prepareToDelete(bot, store: store)
        #expect(problem == nil)
        #expect(cancelled.values.contains("w-1"))
        #expect(cancelled.values.contains("preview:site-1"))
        #expect(run.phase == .canceled)
    }

    @Test func aCancelThatFailsKeepsTheBot() async {
        let (store, bot, runs) = setUp()
        _ = running(store, bot, runs)
        runs.workCanceller = { _ in throw DarkmuxClient.ClientError(message: "darkmux answered 500", status: 500) }
        let problem = await runs.prepareToDelete(bot, store: store)
        #expect(problem != nil, "the bot isn't deleted")
    }

    // 7. Clear Conversation.

    @Test func clearingKeepsTheCardsOfOpenRuns() {
        let (store, bot, _) = setUp()
        let proposed = store.proposeRun(task: "Make it blue", crew: .coder, on: bot)
        store.append(.user, "hello", to: store.conversation(for: .bot(bot.id)))
        store.clearConversation(.bot(bot.id))
        let left = store.conversation(for: .bot(bot.id)).messages ?? []
        #expect(left.contains { $0.runId == proposed.id }, "the waiting dispatch card stays")
        #expect(!left.contains { $0.content == "hello" })
    }

    // 8. Hand-off.

    @Test func anApprovedHandOffIsADispatchCardNotAForeverWorking() {
        let store = TestStore.fresh()
        let from = store.add(name: "lead-ish", instructions: "")
        let target = store.add(name: "hcr", instructions: "")
        let brain = BotBrain()
        let card = store.proposeAction(.handOff(toId: target.id, toName: "hcr", task: "fix the header"), in: .bot(from.id))
        brain.resolve(card, approve: true, store: store)
        #expect(target.runs?.first?.phase == .proposed, "a dispatch card waits in hcr's thread")
        #expect(target.state != .working)
        #expect((target.tasks ?? []).isEmpty)
    }

    @Test func aHandOffToABotThatsGoneSaysSo() {
        let store = TestStore.fresh()
        let from = store.add(name: "lead-ish", instructions: "")
        let brain = BotBrain()
        let card = store.proposeAction(.handOff(toId: UUID(), toName: "old", task: "x"), in: .bot(from.id))
        brain.resolve(card, approve: true, store: store)
        let said = (store.conversation(for: .bot(from.id)).messages ?? []).map(\.content)
        #expect(said.contains { $0.contains("isn't here anymore") }, "\(said)")
    }
}

/// Answers every darkmux request with one status.
final class DarkmuxStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body: String?
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DarkmuxStub.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((Self.body ?? #"{"error":"unknown token"}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
