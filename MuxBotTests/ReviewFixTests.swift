import Foundation
import Testing
@testable import MuxBot

/// Findings from the PR #3 reviews (Grok inline comments, Gemini G2/G3/
/// G9/G10/G11/G13/G14), each pinned by a test that failed first.

@Suite(.serialized) @MainActor
struct ActivityGroupingTests {
    private func run(_ store: BotStore, _ bot: Bot, _ task: String, _ phase: RunPhase, changed: [String] = [], commit: String? = nil) -> BotRun {
        let r = store.proposeRun(task: task, crew: .coder, on: bot)
        r.phase = phase
        r.changedFiles = changed
        r.keptCommit = commit
        return r
    }

    /// Grok 4510124727 / G3: a committed result and a leftover .kept were in
    /// no group, so they vanished from Activity.
    @Test func committedResultsAndKeptRunsAreFinished() {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "")
        let committed = run(store, bot, "committed", .result, changed: ["a.css +1 −1"], commit: "abc1234")
        let kept = run(store, bot, "kept earlier", .kept, changed: ["b.css +1 −0"], commit: "def5678")
        let s = ActivitySections(runs: [committed, kept])
        #expect(Set(s.finished.map(\.task)) == ["committed", "kept earlier"])
        #expect(s.needsYou.isEmpty && s.running.isEmpty)
    }

    /// G3: the badge and the sort follow what actually waits on you.
    @Test func badgeAndRankFollowWhatWaits() {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "")
        let committed = run(store, bot, "committed", .result, changed: ["a.css +1 −1"], commit: "abc1234")
        #expect(ActivityRow.kind(of: committed) == .done)
        #expect(committed.statusRank == 2)
        let question = run(store, bot, "question", .result)
        #expect(ActivityRow.kind(of: question) == .needsYou)
        NeedsYou.dismiss([question])
        #expect(ActivityRow.kind(of: question) != .needsYou, "hidden with the banner's ×")
    }
}

@Suite(.serialized) @MainActor
struct RunFlowReviewTests {
    struct Fake: Error {}

    /// A bot that can run on darkmux: a work copy, and a paired connection
    /// whose token and name never touch the real Keychain or defaults.
    private func setUp() -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.runs.profileSource = { [] }
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-review-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        brain.runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        return (store, bot, brain)
    }

    private func until(_ timeout: Double = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    static func status(_ json: String) -> DarkmuxClient.WorkStatus {
        try! JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(json.utf8))
    }

    /// Grok 4510124738: Stop while the model is being chosen must never let
    /// the run reach darkmux afterwards.
    @Test func stopWhileChoosingTheModelNeverSubmits() async {
        let (store, bot, brain) = setUp()
        let gate = Gate()
        brain.runs.profileSource = { await gate.wait(); return [] }
        let submitted = Counter()
        brain.runs.workSubmitter = { _, _, _, _, _ in submitted.add(); return ("w-1", nil) }
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        brain.runs.decide(.approve, on: run, store: store)
        // Approve before the model is chosen waits on the card for the
        // choice (sweep 7 #3), so Cancel there is the stop.
        #expect(run.phase == .proposed)
        brain.runs.decide(.cancel, on: run, store: store)
        #expect(run.phase == .canceled)
        await gate.open()
        await until(1) { submitted.count > 0 }
        #expect(submitted.count == 0, "never submitted after Stop")
    }

    /// Grok 4510124738: Stop while the submit is in flight cancels the work
    /// darkmux just started.
    @Test func stopDuringTheSubmitCancelsTheNewWork() async {
        let (store, bot, brain) = setUp()
        let gate = Gate()
        let submitting = Counter()
        brain.runs.workSubmitter = { _, _, _, _, _ in submitting.add(); await gate.wait(); return ("w-9", nil) }
        let cancelled = Recorder()
        brain.runs.workCanceller = { cancelled.add($0) }
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        brain.runs.decide(.approve, on: run, store: store)
        await until { submitting.count == 1 }   // the submit is in flight
        await brain.runs.stop(run, store: store)
        await gate.open()
        await until { !cancelled.values.isEmpty }
        #expect(cancelled.values == ["w-9"])
        #expect(run.phase == .canceled)
    }

    /// Grok 4510124741: a reply during Undo is refused, not turned into a tweak.
    @Test func aReplyDuringUndoIsRefused() async {
        let (store, bot, brain) = setUp()
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        run.phase = .result
        run.changedFiles = ["a.css +1 −1"]
        run.keptCommit = "abc1234"
        run.darkmuxWorkId = "w-1"
        brain.runs.markStartedHere(run)
        let gate = Gate()
        brain.runs.workUndoer = { _ in await gate.wait(); return DarkmuxClient.UndoResult.fixture }
        brain.runs.decide(.discard, on: run, store: store)
        await until { brain.runs.deciding.contains(run.id) }
        brain.runs.tweak("make it blue", run: run, store: store)
        #expect(run.phase == .result, "no tweak while Undo is in flight")
        let said = (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
        #expect(said.contains { $0.contains("Undo") && $0.contains("wait") })
        await gate.open()
        await until { run.phase != .result }
        #expect(run.phase == .discarded)
    }

    /// Grok 4510124741: if the run moved on while Undo ran, the undo's
    /// discard isn't applied silently; the thread says they overlapped.
    @Test func anUndoThatOverlapsSaysSo() async {
        let (store, bot, brain) = setUp()
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        run.phase = .result
        run.changedFiles = ["a.css +1 −1"]
        run.keptCommit = "abc1234"
        run.darkmuxWorkId = "w-1"
        brain.runs.markStartedHere(run)
        let gate = Gate()
        brain.runs.workUndoer = { _ in await gate.wait(); return DarkmuxClient.UndoResult.fixture }
        brain.runs.decide(.discard, on: run, store: store)
        await until { brain.runs.deciding.contains(run.id) }
        run.phase = .running   // moved on some other way while darkmux undid it
        await gate.open()
        await until { !brain.runs.deciding.contains(run.id) }
        #expect(run.phase == .running)
        let said = (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
        #expect(said.contains { $0.contains("overlapped") })
    }

    /// Grok 4510124734 / G11: a commit that failed is said, the run waits on
    /// you, and Undo isn't offered for a commit that doesn't exist.
    @Test func aFailedCheckpointIsSaidAndNotUndoable() async {
        let (store, bot, brain) = setUp()
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        run.phase = .running
        await brain.runs.finishRun(run, status: Self.status(#"""
            {"status":"done","changes":{"files":[{"path":"a.css","added":1,"removed":1}]},"commit_error":"nothing to commit: index.lock"}
            """#), store: store)
        #expect(run.phase == .result)
        #expect(run.keptCommit == nil)
        #expect(run.needsYou, "the checkpoint didn't happen: it waits on you")
        #expect(!RunCardState.canUndo(run))
        #expect(RunCardState.checkpointProblem(run) == "nothing to commit: index.lock")
        brain.runs.decide(.discard, on: run, store: store)
        #expect(run.phase == .result, "no undo for a commit that doesn't exist")
        brain.runs.decide(.close, on: run, store: store)
        #expect(run.phase == .done)
    }

    /// G11: a later success clears an old commit error; a tweak that ends in
    /// a question keeps the commit it was built on (so Open PR stays).
    @Test func aTweakKeepsItsCommitAndALaterSuccessClearsTheError() async {
        let (store, bot, brain) = setUp()
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        run.phase = .running
        await brain.runs.finishRun(run, status: Self.status(#"""
            {"status":"done","changes":{"files":[{"path":"a.css","added":1,"removed":1}]},"commit":"abc1234","branch":"mux/site"}
            """#), store: store)
        #expect(run.keptCommit == "abc1234")
        run.details = "an old error"
        run.phase = .running   // tweaked
        await brain.runs.finishRun(run, status: Self.status(#"{"status":"done","result":{"final_assistant":"Which page?"}}"#), store: store)
        #expect(run.keptCommit == "abc1234", "the commit it was built on stays")
        #expect(run.keptBranch == "mux/site")
        #expect(run.details == nil, "no stale error")
        #expect(brain.runs.unshippedRuns(bot, store: store).contains { $0.id == run.id })
    }

    /// G11: a direct tweak forgets the last done-when result.
    @Test func aTweakClearsTheLastCheck() {
        let (store, bot, brain) = setUp()
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        run.phase = .result
        run.changedFiles = ["a.css +1 −1"]
        run.keptCommit = "abc1234"
        brain.runs.runChecks[run.id] = LayoutCheck.Result(met: false, failures: ["still a row"])
        // This Mac's run (sweep 2: another Mac's is refused a Tweak).
        brain.runs.markStartedHere(run)
        brain.runs.workSubmitter = { _, _, _, _, _ in ("w-2", nil) }
        brain.runs.tweak("again", run: run, store: store)
        #expect(brain.runs.runChecks[run.id] == nil)
    }

    /// G9: a read-only crew's run that changed nothing is finished, not a
    /// question; a Coder run that changed nothing is a question with Close.
    @Test func readOnlyRunsAreFinishedAndQuestionsCanBeClosed() {
        let (store, bot, brain) = setUp()
        let review = store.proposeRun(task: "Review it", crew: .reviewer, on: bot)
        review.phase = .result
        #expect(!review.needsYou)
        let research = store.proposeRun(task: "Look into it", crew: .researcher, on: bot)
        research.phase = .result
        #expect(!research.needsYou)
        let question = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        question.phase = .result
        #expect(question.needsYou)
        brain.runs.decide(.close, on: question, store: store)
        #expect(question.phase == .done)
    }

    /// G10: approving or tweaking a run you'd hidden shows it again when it
    /// next needs you.
    @Test func approveAndTweakForgetAHiddenRun() {
        let (store, bot, brain) = setUp()
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        run.phase = .result
        NeedsYou.dismiss([run])
        #expect(NeedsYou.isDismissed(run))
        // This Mac's run (sweep 2: another Mac's is refused a Tweak).
        brain.runs.markStartedHere(run)
        brain.runs.workSubmitter = { _, _, _, _, _ in ("w-3", nil) }
        brain.runs.tweak("try again", run: run, store: store)
        #expect(!NeedsYou.isDismissed(run))
    }

    /// G10, revised in sweep batch 2: a hand-off is a dispatch card waiting
    /// for Approve (Needs you), never "Working" with nothing running.
    @Test func aHandOffWaitsForApproveNotWorking() {
        let (store, bot, _) = setUp()
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        store.handOff(task: "Look at the footer", from: "Mux Bot", to: bot)
        run.phase = .done
        store.refreshState(of: bot)
        #expect(bot.state == .needsYou)
        #expect(bot.runs?.contains { $0.task == "Look at the footer" && $0.phase == .proposed } == true)
    }

    /// Grok 4510124753: a run kept by an earlier build becomes a committed
    /// result, so Open PR includes it.
    @Test func keptRunsMoveBackToResults() {
        let (store, bot, brain) = setUp()
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        run.phase = .kept
        run.changedFiles = ["a.css +1 −1"]
        run.keptCommit = "abc1234"
        let uncommitted = store.proposeRun(task: "Old", crew: .coder, on: bot)
        uncommitted.phase = .kept
        store.migrateKeptRuns()
        #expect(run.phase == .result)
        #expect(uncommitted.phase == .done, "nothing committed: nothing to open a PR from")
        #expect(brain.runs.unshippedRuns(bot, store: store).map(\.id) == [run.id])
    }
}

@Suite(.serialized) @MainActor
struct FollowUpIntentTests {
    private func setUp() -> (BotStore, Bot, BotBrain, BotRun) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.runs.profileSource = { [] }
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-review-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        brain.runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        brain.runs.workSubmitter = { _, _, _, _, _ in ("w-5", nil) }
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        run.phase = .result
        run.changedFiles = ["a.css +1 −1"]
        run.keptCommit = "abc1234"
        run.startedAt = Date().addingTimeInterval(-60)
        run.finishedAt = Date()
        // This Mac's run (sweep 2: another Mac's is refused a Tweak).
        brain.runs.markStartedHere(run)
        return (store, bot, brain, run)
    }

    /// G2: after a result, questions, bug reports, dismissals and asks are
    /// answered as such, never turned into a Coder tweak.
    @Test(arguments: ["what does this do?", "bug: the header overlaps", "thanks", "ask: why blue"])
    func onlyWorkShapedRepliesContinueTheRun(text: String) async {
        let (store, bot, brain, run) = setUp()
        await brain.send(text, in: .bot(bot.id), store: store)
        #expect(run.phase == .result, "\(text) didn't tweak the run")
        #expect(run.tweaks == 0)
    }

    /// G2: a pick from the preview is about the element, not a tweak.
    @Test func aPickIsNotATweak() async {
        let (store, bot, brain, run) = setUp()
        let element = PickedElement.fixture
        await brain.send("make this smaller", in: .bot(bot.id), store: store, element: element)
        #expect(run.phase == .result)
    }

    /// G2: a plain change request after a result still continues it (the
    /// documented "reply to change it").
    @Test func aChangeRequestStillContinuesTheRun() async {
        let (store, bot, brain, run) = setUp()
        await brain.send("make the header blue", in: .bot(bot.id), store: store)
        #expect(run.tweaks == 1)
    }

    /// G2: a proposal you canceled before it started isn't a follow-up target.
    @Test func aCanceledProposalIsNotFollowedUp() async {
        let (store, bot, brain, run) = setUp()
        run.phase = .canceled
        run.startedAt = nil
        await brain.send("make it bigger", in: .bot(bot.id), store: store)
        let cards = (store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.kind == .actionCard }
        #expect(cards.isEmpty, "no 'run it again' card for a run that never ran")
    }
}

/// A one-shot gate a test opens.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func add(_ value: String) { lock.withLock { seen.append(value) } }
    var values: [String] { lock.withLock { seen } }
}

extension DarkmuxClient.UndoResult {
    static let fixture = DarkmuxClient.UndoResult(revert: "def5678", files: ["a.css"])
}

extension PickedElement {
    static let fixture = PickedElement(label: "Hero", selector: "main > section.hero > h1", tag: "h1",
                                       url: "/", viewport: 820, left: 16, right: 16, width: 788, height: 58,
                                       paddingLeft: "0px", paddingRight: "0px", marginLeft: "0px", marginRight: "0px",
                                       x: 16, y: 120, fontSize: "48px", fontWeight: "700", color: "rgb(0, 0, 0)", fontFamily: "system-ui")
}

/// G14: a preview start that runs out of time can be retried; a canceled
/// one isn't a failure; previews waiting for pairing start once it pairs.
@Suite(.serialized) @MainActor
struct PreviewStartTests {
    private func setUp() -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let brain = BotBrain()
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-preview-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        brain.runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        return (store, bot, brain)
    }

    @Test func aStartThatRunsOutOfTimeFailsSoItCanBeRetried() async {
        let (_, bot, brain) = setUp()
        brain.runs.previewDeadline = 0.2
        brain.runs.previewFetcher = { _ in LivePreview(status: .starting) }
        await brain.runs.ensurePreview(for: bot)
        #expect(brain.runs.livePreviews[bot.id]?.status.isFailed == true, "not stuck on Starting")
    }

    @Test func aCanceledStartIsNotAFailure() async {
        let (_, bot, brain) = setUp()
        brain.runs.previewFetcher = { _ in throw CancellationError() }
        await brain.runs.ensurePreview(for: bot)
        #expect(brain.runs.livePreviews[bot.id]?.status.isFailed != true)
    }

    /// darkmux's own refusals (darkmux #3451), word for word at their start.
    private static let off = "previews are off on this machine: a preview runs the workspace's own code (its package.json scripts and whatever they call, which a model may have written) on this machine as you, outside the sandbox. To allow it: `darkmux config set clients.preview.enabled true`"
    private static let cloned = "workspace site-1 was not made from a checkout of yours (it was cloned), so it has no preview: a preview runs only from .darkmux/preview.json in your own checkout."
    private static let noRecipe = "no .darkmux/preview.json in your checkout /Users/me/site: add .darkmux/preview.json to your own checkout of me/site (a copy in the workspace is never read)"

    @Test func previewsOffOnThisMacSaysSoAndCanBeRetried() async {
        let (_, bot, brain) = setUp()
        brain.runs.previewFetcher = { _ in throw DarkmuxClient.ClientError(message: Self.off, status: 403) }
        await brain.runs.ensurePreview(for: bot)
        #expect(brain.runs.livePreviews[bot.id]?.status == .unavailable(.previewsOff))
        // Turned on in Terminal: Try again starts it.
        brain.runs.previewFetcher = { _ in LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:5173")) }
        await brain.runs.ensurePreview(for: bot)
        #expect(brain.runs.livePreviews[bot.id]?.status == .ready)
    }

    @Test func aMissingSetupSaysWhichOne() async {
        let (_, bot, brain) = setUp()
        brain.runs.previewFetcher = { _ in throw DarkmuxClient.ClientError(message: Self.noRecipe, status: 404) }
        await brain.runs.ensurePreview(for: bot)
        #expect(brain.runs.livePreviews[bot.id]?.status == .unavailable(.noRecipe))
        #expect(brain.runs.noRecipe.contains(bot.id), "the thread offers to set one up")
        brain.runs.noRecipe.remove(bot.id)
        brain.runs.previewFetcher = { _ in throw DarkmuxClient.ClientError(message: Self.cloned, status: 404) }
        await brain.runs.ensurePreview(for: bot)
        #expect(brain.runs.livePreviews[bot.id]?.status == .unavailable(.notYourCheckout))
        #expect(!brain.runs.noRecipe.contains(bot.id), "a clone has no checkout to write a recipe into")
        bot.useCaseId = "website"
        await brain.runs.ensurePreview(for: bot)
        #expect(brain.runs.livePreviews[bot.id]?.status == .unavailable(.newProject), "a template's project has no checkout of yours")
    }

    @Test func anyOtherRefusalIsAFailureInDarkmuxsWords() async {
        let (_, bot, brain) = setUp()
        brain.runs.previewFetcher = { _ in throw DarkmuxClient.ClientError(message: "config.json does not parse", status: 503) }
        await brain.runs.ensurePreview(for: bot)
        #expect(brain.runs.livePreviews[bot.id]?.status == .failed("config.json does not parse"))
    }

    @Test func aPreviewLinkIsStillShownWhenDarkmuxWontRunOne() {
        let link = URL(string: "https://example.com")!
        #expect(LivePreview.url(darkmux: LivePreview(status: .unavailable(.previewsOff)), resource: link) == link)
        #expect(LivePreview.url(darkmux: LivePreview(status: .unavailable(.noRecipe)), resource: nil) == nil)
    }

    @Test func pairingStartsTheWaitingPreviews() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let brain = BotBrain()
        let connection = FleetConnection(keychain: MemoryKeychain(), defaults: UserDefaults(suiteName: "muxbot-tests-preview-\(UUID().uuidString)")!)
        brain.runs.connection = connection
        await brain.runs.ensurePreview(for: bot)
        // Sweep batch 2: unpaired is said plainly (with Pair), not "waiting".
        #expect(brain.runs.livePreviews[bot.id]?.status == .unavailable(.notPaired))
        let retried = Recorder()
        brain.runs.retryPreview = { retried.add($0.name) }
        connection.completePairing(token: "t0ken", name: "Mux Bot")
        #expect(retried.values == ["site"])
    }
}
