import Foundation
import Testing
@testable import MuxBot

/// Sweep 2, chat: results, Tweaks and questions hold up.
@Suite(.serialized) @MainActor
struct ChatSweep2Tests {
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
        let defaults = UserDefaults(suiteName: "muxbot-tests-s2chat-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        brain.runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        brain.runs.pollInterval = 0.02
        return (store, bot, brain)
    }

    private func committed(_ store: BotStore, _ bot: Bot, _ runs: RunCoordinator, task: String = "Make it warm", crew: CrewRole = .coder) -> BotRun {
        let run = store.proposeRun(task: task, crew: crew, on: bot)
        store.apply(.approve, to: run)
        run.darkmuxWorkId = "w-1"
        runs.markStartedHere(run)
        runs.recordWork("w-1", for: run)
        run.changedFiles = crew.changesFiles ? ["src/styles.css +3 −1"] : []
        if crew.changesFiles { run.keptCommit = "c0ffee1"; run.keptBranch = "mux/site" }
        store.apply(.finish(summary: "I warmed up the colors."), to: run)
        return run
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

    // 1: only a later result replaces an earlier one.

    @Test func aLaterRunThatFailedOrStoppedNeverHidesTheResult() {
        let (store, bot, brain) = setUp()
        let a = committed(store, bot, brain.runs)
        a.createdAt = Date(timeIntervalSince1970: 1_000)
        let failed = store.proposeRun(task: "b", crew: .coder, on: bot)
        failed.createdAt = Date(timeIntervalSince1970: 2_000)
        store.apply(.approve, to: failed)
        store.apply(.fail(reason: "didn't start", details: nil), to: failed)
        #expect(!RunCardState.isReplaced(a), "a failed run never replaces it")
        let stopped = store.proposeRun(task: "c", crew: .coder, on: bot)
        stopped.createdAt = Date(timeIntervalSince1970: 3_000)
        store.apply(.approve, to: stopped)
        store.apply(.stop, to: stopped)
        #expect(!RunCardState.isReplaced(a))
        let later = committed(store, bot, brain.runs, task: "d")
        later.createdAt = Date(timeIntervalSince1970: 4_000)
        #expect(RunCardState.isReplaced(a), "a later result does")
    }

    // 2: a Tweak across a relaunch.

    @Test func aQueuedTweakAcrossARelaunchGoesBackToItsResult() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain.runs)
        brain.runs.workSubmitter = { _, _, _, _, _ in throw DarkmuxClient.ClientError(message: "busy", status: 429) }
        brain.runs.tweak("make it blue", run: run, store: store)
        await until { said(store, bot).contains(RunCoordinator.waitingForSlot) }
        #expect(run.darkmuxWorkId == nil, "the earlier turn's id is never followed as the Tweak's")
        let relaunched = RunCoordinator()
        relaunched.connection = brain.runs.connection
        let fetched = Recorder()
        relaunched.workStatusFetcher = { id in fetched.add(id); return status(#"{"status":"done"}"#) }
        relaunched.resumeFollowing(store: store)
        #expect(run.phase == .result)
        #expect(run.summary == "I warmed up the colors.")
        #expect(run.keptCommit == "c0ffee1")
        #expect(said(store, bot).last?.contains("didn't start before Mux Bot quit") == true, "\(said(store, bot).last ?? "")")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(fetched.values.isEmpty, "the old result is never posted again")
    }

    @Test func aTweakRunningAcrossARelaunchStillHasItsResultToGoBackTo() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain.runs)
        brain.runs.workSubmitter = { _, _, _, _, _ in ("w-2", nil) }
        brain.runs.workStatusFetcher = { _ in status(#"{"status":"running"}"#) }
        brain.runs.tweak("make it blue", run: run, store: store)
        await until { run.darkmuxWorkId == "w-2" }
        let relaunched = RunCoordinator()
        relaunched.connection = brain.runs.connection
        relaunched.pollInterval = 0.02
        relaunched.workStatusFetcher = { _ in status(#"{"status":"error","error":"boom"}"#) }
        relaunched.resumeFollowing(store: store)
        await until { run.phase != .running }
        #expect(run.phase == .result)
        #expect(run.keptCommit == "c0ffee1", "Undo and Open PR survive")
    }

    // 3: Stop before darkmux has the Tweak.

    @Test func stoppingATweakDarkmuxDoesntHaveYetPutsTheResultBack() async {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain.runs)
        brain.runs.workSubmitter = { _, _, _, _, _ in throw DarkmuxClient.ClientError(message: "busy", status: 429) }
        let cancelled = Recorder()
        brain.runs.workCanceller = { cancelled.add($0) }
        brain.runs.tweak("make it blue", run: run, store: store)
        await until { said(store, bot).contains(RunCoordinator.waitingForSlot) }
        await brain.runs.stop(run, store: store)
        #expect(cancelled.values.isEmpty, "nothing on darkmux to stop")
        #expect(run.phase == .result)
        #expect(said(store, bot).last == "Stopped the change. The result before it is unchanged.")
        let submitted = Recorder()
        brain.runs.workSubmitter = { _, _, _, _, _ in submitted.add("x"); return ("w-3", nil) }
        brain.runs.slotFreed(store: store)
        #expect(submitted.values.isEmpty, "it's no longer waiting for a slot")
    }

    // 4: a polite request is work; a stripped action never says Approve.

    @Test func aPoliteChangeRequestIsWork() {
        #expect(Intent.infer("Can you change the header color?", hasElement: false) == .fix)
        #expect(Intent.infer("could you make the title bigger?", hasElement: false) == .fix)
        #expect(Intent.infer("can you explain how the header works?", hasElement: false) == .ask)
    }

    @Test func aQuestionNeverOffersAnApproveWithNoCard() async {
        let (store, bot, brain) = setUp()
        await brain.send("ask: review the footer code", in: .bot(bot.id), store: store)
        let replies = (store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.role == .assistant }.map(\.content)
        #expect(!replies.contains { $0.contains("Approve") }, "\(replies)")
        #expect((bot.runs ?? []).isEmpty)
    }

    // 5: a hand-off from the issue list carries the issue's brief.

    @Test func aHandOffCarriesTheIssuesBrief() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        store.addResource(.repo, "https://github.com/kain/site", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: [GitHubIssue(number: 8, title: "Gutter", body: "Open /pricing; selector `main > div`")])
        let card = store.proposeAction(.handOff(toId: bot.id, toName: "site", task: "Fix #8: Gutter (kain/site)"), in: .lead)
        brain.resolve(card, approve: true, store: store)
        await brain.handingOff?.value
        let run = try #require((bot.runs ?? []).first { $0.phase == .proposed })
        #expect(run.brief?.contains("/pricing") == true, "\(run.brief ?? "nil")")
    }

    // 6: the bot's one question doesn't swallow what comes next.

    private func askOne(_ brain: BotBrain, _ bot: Bot, at: Date = .now) {
        brain.pendingAnswers[bot.id] = PendingDispatch(task: "Add a page", crew: .coder, askedAt: at) { "Add a page: \($0)" }
    }

    @Test func neverMindDropsTheQuestion() async {
        let (store, bot, brain) = setUp()
        askOne(brain, bot)
        await brain.send("never mind", in: .bot(bot.id), store: store)
        #expect(brain.pendingAnswers[bot.id] == nil)
    }

    @Test func anotherKindOfRequestDropsIt() async {
        let (store, bot, brain) = setUp()
        askOne(brain, bot)
        await brain.send("review: check the footer", in: .bot(bot.id), store: store)
        #expect(brain.pendingAnswers[bot.id] == nil)
        #expect(!(bot.runs ?? []).contains { $0.task == "Add a page" })
    }

    @Test func aQuestionKeepsIt() async {
        let (store, bot, brain) = setUp()
        askOne(brain, bot)
        await brain.send("what pages are there?", in: .bot(bot.id), store: store)
        #expect(brain.pendingAnswers[bot.id] != nil)
    }

    @Test func itExpires() async {
        let (store, bot, brain) = setUp()
        askOne(brain, bot, at: Date().addingTimeInterval(-3600))
        await brain.send("the about page", in: .bot(bot.id), store: store)
        #expect(!(bot.runs ?? []).contains { $0.task == "Add a page" })
    }

    // 7: "the page fits" only for the page running off the side.

    @Test(arguments: ["it runs off the screen", "the page scrolls sideways", "it's wider than the screen"])
    func pageOverflow(_ text: String) { #expect(BugReport.isPageOverflowComplaint(text)) }

    @Test(arguments: ["the card is cut off", "the title is clipped", "it overflows the box"])
    func notPageOverflow(_ text: String) { #expect(!BugReport.isPageOverflowComplaint(text)) }

    @Test func aPickedElementOffTheScreenIsStillABug() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        store.addResource(.previewURL, "http://127.0.0.1:5999/", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let fits = { (w: Int) in LayoutFacts(viewport: w, scrollWidth: w, clientWidth: w, wide: [], media: [], sections: []) }
        brain.layoutProbe = MockProbe([422: fits(422), 390: fits(390), 768: fits(768), 1440: fits(1440)])
        await brain.send("this card runs off the screen", in: .bot(bot.id), store: store, element: PickedElement.fixture)
        #expect((store.conversation(for: .bot(bot.id)).messages ?? []).contains { $0.kind == .bugCard })
    }

    // 8: a canceled fix is unsent.

    @Test func aCanceledFixCanBeSentAgain() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let card = store.append(.assistant, "bug", kind: .bugCard, to: store.conversation(for: .bot(bot.id)))
        let draft = BugDraft(title: "Gutter", described: "no gutter", page: "/", viewport: 390, facts: [], repo: nil)
        let (first, _) = store.fixBug(card, draft: draft, bot: bot)
        #expect(store.sentRun(for: card)?.id == first.id)
        store.apply(.cancel, to: first)
        #expect(store.sentRun(for: card) == nil, "Fix it now again")
        let (second, isNew) = store.fixBug(card, draft: draft, bot: bot)
        #expect(isNew)
        #expect(second.id != first.id)
    }

    @Test func aBugCardYouDontWantCanBeDismissed() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let thread = store.conversation(for: .bot(bot.id))
        let card = store.append(.assistant, "bug", kind: .bugCard, to: thread)
        let sent = store.append(.assistant, "bug", kind: .bugCard, to: thread)
        let draft = BugDraft(title: "Gutter", described: "no gutter", page: "/", viewport: 390, facts: [], repo: nil)
        _ = store.fixBug(sent, draft: draft, bot: bot)
        #expect(!store.dismissBug(sent), "a card sent to Coder is canceled on its run card")
        #expect(store.dismissBug(card))
        #expect(!(thread.messages ?? []).contains { $0.id == card.id })
        #expect((thread.messages ?? []).contains { $0.id == sent.id })
    }

    // 9: a correction is only the correction.

    @Test func aCorrectionIsOnlyTheCorrection() {
        #expect(Intent.correction(in: "Actually, also fix the footer") == nil)
        #expect(Intent.correction(in: "no, it's a question") == .ask)
        #expect(Intent.correction(in: "not a bug, just asking") == .ask)
        #expect(Intent.correction(in: "actually, fix it") == .fix)
    }

    // 10: what needs you, by crew and commit.

    @Test func whatNeedsMeSortsByCrewAndCommit() {
        let (store, bot, brain) = setUp()
        let review = committed(store, bot, brain.runs, task: "Review the footer", crew: .reviewer)
        let question = committed(store, bot, brain.runs, task: "Which page?", crew: .coder)
        question.changedFiles = []
        question.keptCommit = nil
        let unsaved = committed(store, bot, brain.runs, task: "Warm colors", crew: .coder)
        unsaved.keptCommit = nil
        let all = [review, question, unsaved]
        let sections = WorkStatus.summary(runs: all).components(separatedBy: "\n\n")
        let questions = sections.first { $0.hasPrefix("Questions for you") } ?? ""
        #expect(questions.contains("Which page?"))
        #expect(!questions.contains("Review the footer"), "a review's result isn't a question")
        #expect(sections.contains { $0.hasPrefix("Changes not saved") && $0.contains("Warm colors") })
        #expect(sections.contains { $0.hasPrefix("Finished") && $0.contains("Review the footer") })
        let nudges = WorkStatus.nudges(runs: all, now: Date().addingTimeInterval(86400 * 3))
        #expect(nudges.count == 1 && nudges[0].contains("Which page?"))
    }

    // Leftover (earlier #7): runs already in a PR stay shipped.

    @Test func clearingTheThreadKeepsRunsInAPRShipped() {
        let (store, bot, brain) = setUp()
        let run = committed(store, bot, brain.runs)
        run.finishedAt = Date().addingTimeInterval(-60)
        store.append(.system, "Opened PR #5: https://github.com/kain/site/pull/5", kind: .prCard, runId: run.id, to: store.conversation(for: .bot(bot.id)))
        #expect(brain.runs.unshippedRuns(bot, store: store).isEmpty)
        store.clearConversation(.bot(bot.id))
        #expect(brain.runs.unshippedRuns(bot, store: store).isEmpty, "Open PR doesn't come back")
    }

    @Test func openingAPRMarksItsRunsShipped() async {
        let (store, bot, brain) = setUp()
        store.addResource(.repo, "https://github.com/kain/site", to: bot)
        _ = committed(store, bot, brain.runs)
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kain/site/git/commits/b0", 200, #"{"sha":"b0","tree":{"sha":"t0"}}"#)
        GitHubStub.on("POST /repos/kain/site/git/blobs", 201, #"{"sha":"n1"}"#)
        GitHubStub.on("POST /repos/kain/site/git/trees", 201, #"{"sha":"t1"}"#)
        GitHubStub.on("POST /repos/kain/site/git/commits", 201, #"{"sha":"c1"}"#)
        GitHubStub.on("POST /repos/kain/site/git/refs", 201, #"{"ref":"refs/heads/mux/site"}"#)
        GitHubStub.on("POST /repos/kain/site/pulls", 201, #"{"number":5,"html_url":"https://github.com/kain/site/pull/5"}"#)
        brain.runs.githubSession = GitHubStub.session
        brain.runs.changesFetcher = { _ in DarkmuxClient.Changes(base: "b0", baseBranch: "main", head: "h", branch: "mux/site",
                                                                  files: [.init(path: "a.css", mode: nil, content: "eA==", deleted: nil)]) }
        let keychain = MemoryKeychain()
        keychain.items[GitHubAuth.tokenKey] = "ghu"
        let github = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, sleep: { _ in })
        await brain.runs.openPR(for: bot, store: store, github: github)
        #expect(said(store, bot).contains { $0.contains("pull request #5") }, "\(said(store, bot))")
        #expect(LocalBotState.shared[bot.id]?.shippedThrough != nil)
    }
}
