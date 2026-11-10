import Foundation
import Testing
@testable import MuxBot

/// Sweep batch 3: runs and Tweaks never lose a result, and the chat routes
/// each message to the right thing.
@Suite(.serialized) @MainActor
struct RunLoopSweepTests {
    private func setUp() -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.runs.profileSource = { [] }
        brain.runs.deviceRuns = true
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-sweep3-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        brain.runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        brain.runs.pollInterval = 0.02
        return (store, bot, brain)
    }

    /// A finished Coder run with a commit, as darkmux leaves it.
    private func committed(_ store: BotStore, _ bot: Bot, _ brain: BotBrain, crew: CrewRole = .coder, workId: String = "w-1") -> BotRun {
        let run = store.proposeRun(task: "Make it warm", crew: crew, on: bot)
        store.apply(.approve, to: run)
        run.darkmuxWorkId = workId
        brain.runs.markStartedHere(run)
        brain.runs.recordWork(workId, for: run)
        run.changedFiles = crew.changesFiles ? ["src/styles.css +3 −1"] : []
        if crew.changesFiles { run.keptCommit = "c0ffee1"; run.keptBranch = "mux/site" }
        store.apply(.finish(summary: "I warmed up the colors."), to: run)
        return run
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

    // Chat 1: "Replaced by the next run" only by a later run that ran.

    @Test func aWaitingOrCanceledLaterRunReplacesNothing() {
        let (store, bot, brain) = setUp()
        let result = committed(store, bot, brain)
        let waiting = store.proposeRun(task: "next", crew: .coder, on: bot)
        #expect(!RunCardState.isReplaced(result), "a run still waiting for Approve")
        store.apply(.cancel, to: waiting)
        #expect(!RunCardState.isReplaced(result), "a canceled proposal never ran")
        let ran = store.proposeRun(task: "later", crew: .coder, on: bot)
        store.apply(.approve, to: ran)
        ran.startedAt = Date()
        // Sweep 2 #1: replaced once the later run has a result.
        store.apply(.finish(summary: "later"), to: ran)
        #expect(RunCardState.isReplaced(result))
    }

    @Test func aRunThatStillNeedsYouIsNeverCollapsed() {
        let (store, bot, brain) = setUp()
        let question = committed(store, bot, brain)
        question.changedFiles = []
        question.keptCommit = nil   // a question: needs you
        let ran = store.proposeRun(task: "later", crew: .coder, on: bot)
        store.apply(.approve, to: ran)
        ran.startedAt = Date()
        #expect(question.needsYou)
        #expect(!RunCardState.isReplaced(question))
    }

    // Chat 2 / seam 4: a Tweak that can't start, fails or is stopped leaves the result.

    @Test func aTweakThatCantStartPutsTheResultBack() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain)
        brain.runs.workSubmitter = { _, _, _, _, _ in throw DarkmuxClient.ClientError(message: "darkmux answered 500", status: 500) }
        brain.runs.tweak("make it blue", run: run, store: store)
        await until { run.phase != .running }
        #expect(run.phase == .result)
        #expect(run.summary == "I warmed up the colors.")
        #expect(RunCardState.canUndo(run), "Undo survives")
        #expect(brain.runs.unshippedRuns(bot, store: store).contains { $0.id == run.id }, "and Open PR")
        #expect(said(store, bot).last?.contains("didn't start") == true, "\(said(store, bot).last ?? "")")
    }

    @Test func aTweakDarkmuxWontContinueStartsFresh() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain)
        let sent = Recorder()
        brain.runs.workSubmitter = { _, _, _, _, continues in
            sent.add(continues ?? "fresh")
            if continues != nil { throw DarkmuxClient.ClientError(message: "too old to continue", status: 409) }
            return ("w-2", nil)
        }
        brain.runs.workStatusFetcher = { _ in try JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(#"{"status":"running"}"#.utf8)) }
        brain.runs.tweak("make it blue", run: run, store: store)
        await until { sent.values.count == 2 }
        #expect(sent.values == ["w-1", "fresh"])
        #expect(run.phase == .running)
        run.phase = .canceled
    }

    @Test func aStoppedTweakLeavesTheResult() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain)
        brain.runs.workSubmitter = { _, _, _, _, _ in ("w-2", nil) }
        brain.runs.workCanceller = { _ in }
        brain.runs.workStatusFetcher = { [self] _ in status(#"{"status":"running"}"#) }
        brain.runs.tweak("make it blue", run: run, store: store)
        await until { run.darkmuxWorkId == "w-2" }
        await brain.runs.stop(run, store: store)
        #expect(run.phase == .result)
        #expect(run.summary == "I warmed up the colors.")
        #expect(RunCardState.canUndo(run))
    }

    @Test func aTweakThatFailsLeavesTheResult() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain)
        brain.runs.workSubmitter = { _, _, _, _, _ in ("w-2", nil) }
        brain.runs.workStatusFetcher = { [self] _ in status(#"{"status":"error","error":"boom","reason":"failed","code":"busy"}"#) }
        brain.runs.tweak("make it blue", run: run, store: store)
        await until { run.phase != .running }
        #expect(run.phase == .result)
        #expect(run.summary == "I warmed up the colors.")
        #expect(said(store, bot).last?.contains("busy") == true)
    }

    // Seam 3: every work id of a run, undone newest first.

    @Test func undoRevertsEveryTurnNewestFirst() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain)
        brain.runs.recordWork("w-2", for: run)
        run.darkmuxWorkId = "w-2"
        let undone = Recorder()
        brain.runs.workUndoer = { undone.add($0); return DarkmuxClient.UndoResult.fixture }
        brain.runs.decide(.discard, on: run, store: store)
        await until { run.phase != .result }
        #expect(undone.values == ["w-2", "w-1"])
        #expect(run.phase == .discarded)
    }

    @Test func aRefusedEarlierUndoLeavesTheResult() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain)
        brain.runs.recordWork("w-2", for: run)
        run.darkmuxWorkId = "w-2"
        brain.runs.workUndoer = { id in
            if id == "w-1" { throw DarkmuxClient.ClientError(message: "a later run changed the same files", status: 409) }
            return DarkmuxClient.UndoResult.fixture
        }
        brain.runs.decide(.discard, on: run, store: store)
        await until { !brain.runs.deciding.contains(run.id) && brain.runs.decisionErrors[run.id] != nil }
        #expect(run.phase == .result)
        #expect(brain.runs.decisionErrors[run.id] != nil)
    }

    @Test func aTweaksFilesAddToTheRunsFiles() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain)
        store.apply(.tweak, to: run)
        await brain.runs.finishRun(run, status: status(#"{"status":"done","changes":{"files":[{"path":"index.html","added":1,"removed":0}]},"commit":"d00d","branch":"mux/site"}"#), store: store)
        #expect(run.changedFiles.contains { $0.hasPrefix("src/styles.css") })
        #expect(run.changedFiles.contains { $0.hasPrefix("index.html") })
    }

    // Seam 12: changes_error and fetch_error are said.

    @Test func changesDarkmuxCouldntReadAreNotNothing() async {
        let (store, bot, brain) = setUp()
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        await brain.runs.finishRun(run, status: status(#"{"status":"done","changes":null,"changes_error":"git status failed"}"#), store: store)
        #expect(run.details?.contains(RunResultText.changesUnreadable) == true, "\(run.details ?? "nil")")
    }

    @Test func aStaleWorkCopySaysSo() async throws {
        let (store, bot, brain) = setUp()
        bot.workspaceName = nil
        store.addResource(.repo, "https://github.com/kstrat2001/site", to: bot)
        brain.runs.workspaceMaker = { _ in
            try JSONDecoder().decode(DarkmuxClient.Workspace.self, from: Data(#"{"workspace":"site-2","branch":"mux/site","fetch_error":"could not resolve host"}"#.utf8))
        }
        await brain.runs.setUpWorkCopy(for: bot, store: store)
        #expect(said(store, bot).contains { $0.contains(RunCoordinator.staleBase) }, "\(said(store, bot))")
    }

    // Seam 14: a third run waits for a free slot.

    @Test func aRunDarkmuxHasNoRoomForWaitsAndStartsLater() async {
        let (store, bot, brain) = setUp()
        let calls = Recorder()
        brain.runs.workSubmitter = { _, _, _, _, _ in
            calls.add("submit")
            if calls.values.count == 1 { throw DarkmuxClient.ClientError(message: "too many running", status: 429) }
            return ("w-9", nil)
        }
        brain.runs.workStatusFetcher = { [self] _ in status(#"{"status":"running"}"#) }
        let run = store.proposeRun(task: "third", crew: .coder, on: bot)
        brain.runs.decide(.approve, on: run, store: store)
        await until { said(store, bot).contains(RunCoordinator.waitingForSlot) }
        #expect(run.phase == .running, "approved and waiting, not failed")
        brain.runs.slotFreed(store: store)
        await until { run.darkmuxWorkId == "w-9" }
        #expect(run.darkmuxWorkId == "w-9")
        run.phase = .canceled
    }

    // Chat 3: read-only results.

    @Test func aReviewerResultIsNotTweakedByTheNextMessage() async {
        let (store, bot, brain) = setUp()
        let review = committed(store, bot, brain, crew: .reviewer)
        brain.runs.workSubmitter = { _, _, _, _, _ in ("w-2", nil) }
        await brain.send("make the header blue", in: .bot(bot.id), store: store)
        #expect(review.tweaks == 0)
        #expect(review.phase == .result)
        #expect(RunCardState.canClose(review), "a read-only result has Done")
    }

    // Chat 4: the follow-up offer comes once.

    @Test func aDeclinedFollowUpIsNotOfferedAgain() async {
        let (store, bot, brain) = setUp()
        let run = store.proposeRun(task: "Make it warm", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        run.startedAt = Date()
        store.apply(.fail(reason: "Didn't finish: x", details: nil), to: run)
        await brain.send("make the header blue", in: .bot(bot.id), store: store)
        let offers = { (store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.kind == .actionCard } }
        #expect(offers().count == 1)
        brain.resolve(offers()[0], approve: false, store: store)
        await brain.send("make the footer green", in: .bot(bot.id), store: store)
        #expect(offers().count == 1, "no second follow-up offer")
    }

    // Chat 5: corrections are whole words.

    @Test(arguments: ["now make it blue", "note the header is too big", "nothing changed here", "notice the footer", "no-code is fine"])
    func theseAreNotCorrections(text: String) {
        #expect(Intent.correction(in: text) == nil, "\(text)")
    }

    @Test(arguments: [("no, it's a question", Intent.ask), ("not a bug, just asking", .ask), ("actually, fix it", .fix), ("nope, a bug", .bug)])
    func theseAre(text: String, intent: Intent) {
        #expect(Intent.correction(in: text) == intent, "\(text)")
    }

    @Test func cueWordsAreWholeWords() {
        #expect(Intent.correction(in: "no, that's a task") == nil, "\"ask\" inside \"task\"")
    }

    @Test func aCorrectionStopsTheTweakTheMisreadStarted() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain)
        brain.runs.workSubmitter = { _, _, _, _, _ in ("w-2", nil) }
        brain.runs.workCanceller = { _ in }
        brain.runs.workStatusFetcher = { [self] _ in status(#"{"status":"running"}"#) }
        await brain.send("make the header smaller", in: .bot(bot.id), store: store)   // a change request: a Tweak
        await until { run.darkmuxWorkId == "w-2" }
        #expect(run.darkmuxWorkId == "w-2", "the misread started a tweak")
        await brain.send("no, it's a question", in: .bot(bot.id), store: store)
        await until { run.phase != .running }
        #expect(run.phase == .result, "the misread tweak is stopped; the result stays")
    }

    // Chat 6: a pending question takes only an answer.

    @Test func aQuestionIsNotTakenAsTheAnswer() async {
        let (store, bot, brain) = setUp()
        bot.skills = [BotSkill(name: "Change the look", body: "When: \"make it warmer\"")]
        await brain.send("Change the look", in: .bot(bot.id), store: store)
        await brain.send("how big is the header?", in: .bot(bot.id), store: store)
        #expect(bot.runs?.isEmpty ?? true, "a question doesn't become the run")
        #expect(brain.pendingAnswers[bot.id] != nil, "still waiting for the answer")
        #expect(!ChatShortcuts.showsRow(draft: "", tweaking: false, picked: false, waitingCard: false, lead: false, answerPending: true))
    }

    // Chat 11: the keyword fallback.

    @Test func aChangeWithAFleetWordIsWork() {
        let turn = FallbackBrain.turn(for: "Add a free plan to the pricing page and mark it busy", speaker: BotSummary.fixture("site"), bots: [])
        #expect(turn.reply != FallbackBrain.fleetAnswer, "a request isn't a question about the fleet")
        let update = FallbackBrain.turn(for: "Update the pricing page; the server is busy", speaker: BotSummary.fixture("site"), bots: [])
        if case .dispatch? = update.action {} else { Issue.record("expected work, got \(update.reply)") }
    }

    @Test func aBotNameInsideAnotherBotsRequestIsNotAHandOff() {
        let me = BotSummary.fixture("app"), site = BotSummary.fixture("site")
        let turn = FallbackBrain.turn(for: "update the site footer", speaker: me, bots: [me, site])
        if case .handOff? = turn.action { Issue.record("not a hand-off: \(turn.reply)") }
    }

    @Test func aPathInARequestIsNotAFolder() {
        let turn = FallbackBrain.turn(for: "Update the copy on /pricing", speaker: BotSummary.fixture("site"), bots: [])
        if case .addResource? = turn.action { Issue.record("not a resource: \(turn.reply)") }
    }

    @Test func approvingAFolderResourceIsRefused() {
        let (store, bot, brain) = setUp()
        let card = store.proposeAction(.addResource(kind: .folder, value: "/pricing"), in: .bot(bot.id))
        brain.resolve(card, approve: true, store: store)
        #expect(!(bot.resources ?? []).contains { $0.kind == .folder })
    }

    // Chat 12: status words in a request.

    @Test(arguments: ["fix the status bar", "add a status page", "they need me to change the logo"])
    func requestsWithStatusWordsAreWork(text: String) {
        #expect(!WorkStatus.isWorkQuestion(text.lowercased()), "\(text)")
    }

    @Test(arguments: ["what's the status?", "status?", "what needs me?", "what's running"])
    func statusQuestionsStillAre(text: String) {
        #expect(WorkStatus.isWorkQuestion(text.lowercased()), "\(text)")
    }

    // Chat 13: thinking is per thread.

    @Test func thinkingInOneThreadIsNotThinkingInAnother() {
        let brain = BotBrain()
        let a = ChatContext.bot(UUID())
        brain.beginThinking(a)
        #expect(brain.isThinking(in: a))
        #expect(!brain.isThinking(in: .lead))
        brain.endThinking(a)
        #expect(!brain.isThinking(in: a))
    }

    // Chat 17: Run again is one tap.

    @Test func runAgainTwiceStartsOnce() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain)
        let submitted = Recorder()
        brain.runs.workSubmitter = { _, _, _, _, _ in submitted.add("x"); return ("w-2", nil) }
        brain.runs.workStatusFetcher = { [self] _ in status(#"{"status":"running"}"#) }
        // Two taps before the first one's await returns.
        let first = Task { await brain.rerun(run, change: "again", store: store, nextModel: true) }
        let second = Task { await brain.rerun(run, change: "again", store: store, nextModel: true) }
        _ = await (first.value, second.value)
        await until { !submitted.values.isEmpty }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(submitted.values.count == 1)
        #expect(bot.runs?.count == 1, "the second tap makes no second run")
        #expect(!said(store, bot).contains { $0.hasPrefix("Can't run this yet") })
        run.phase = .canceled
    }

    // Chat 20: the banner says what it is.

    @Test func anUncommittedResultIsNotCalledAQuestion() {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain)
        run.keptCommit = nil
        run.details = "index.lock"
        #expect(NeedsYou.bannerLine(for: run) == "Coder's changes weren't saved: Make it warm")
    }
}

extension BotSummary {
    static func fixture(_ name: String) -> BotSummary {
        BotSummary(id: UUID(), name: name, instructions: "", state: .ready, resources: [])
    }
}
