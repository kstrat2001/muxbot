import Foundation
import Testing
@testable import MuxBot

struct IntentParsingTests {
    @Test(arguments: [
        ("bug: the box has no margin", Intent.bug, "the box has no margin"),
        ("Fix: tighten the footer", .fix, "tighten the footer"),
        ("review:the pricing diff", .review, "the pricing diff"),
        ("ask: why is this green?", .ask, "why is this green?"),
        ("issues: anything open?", .issues, "anything open?"),
    ])
    func prefixes(text: String, intent: Intent, body: String) {
        let (parsed, rest) = Intent.parse(text)
        #expect(parsed == intent)
        #expect(rest == body)
    }

    @Test func unknownPrefixIsJustText() {
        let (parsed, rest) = Intent.parse("note: remember the margins")
        #expect(parsed == nil)
        #expect(rest == "note: remember the margins")
    }

    @Test(arguments: [
        ("any open bug tickets?", false, Intent.issues),
        ("the border has no padding", false, .bug),
        ("make it bigger", true, .fix),
        ("what is this font?", true, .ask),
        // One "Chat about this" in the preview: what you type decides.
        ("replace the phone number with 555-0100", true, .fix),
        ("please make this bigger", true, .fix),
        ("can you make this bigger?", true, .fix),
        ("why is this cut off", true, .bug),
        ("why is this cut off?", true, .bug),
        ("what font is this", true, .ask),
        ("no gutter on the sides", true, .bug),
        // A design change names a color or a border, yet it's work, not a bug.
        ("change the green color to a white", false, .fix),
        ("chanage the green color to a white", false, .fix),
        ("repalce the logo with the new one", false, .fix),
        ("make the border thicker", false, .fix),
        ("the header color should be white", false, .fix),
        ("i want the footer font bigger", false, .fix),
        // A remark about what you see is still measured into a bug.
        ("the Start_a_Project border looks like it has no padding on left and right", false, .bug),
        ("the cards overlap the footer on phone", false, .bug),
        // A rule for the content is a change, never a layout bug to measure.
        ("We shouldn't use brand names", false, .fix),
        ("We shouldn't use brand names", true, .fix),
        ("don't mention AWS", true, .fix),
        ("the footer should not say 2024", false, .fix),
        ("no more stock photos", false, .fix),
        ("this shouldn't be cut off", true, .bug),
        // With something picked, a request that isn't about layout is a change.
        ("Offer a better list", true, .fix),
        ("more examples here", true, .fix),
        ("a friendlier headline", true, .fix),
        ("the cards overlap the footer on phone", true, .bug),
        ("there's no space between these", true, .bug),
        // Questions stay questions; one typo never makes a short word a verb.
        ("should the header be white?", false, .ask),
        // Naming an issue in a change is never a list of GitHub issues.
        ("change \"logic flaws\" to a different security issue", true, .fix),
        ("change \"logic flaws\" to a different security issue", false, .fix),
        ("rename the bug section to Known problems", false, .fix),
        ("any open issues?", false, .issues),
        ("show me the open issues", false, .issues),
        ("can you list the issues", false, .issues),
    ])
    func inference(text: String, hasElement: Bool, intent: Intent) {
        #expect(Intent.infer(text, hasElement: hasElement) == intent)
    }

    @Test(arguments: ["the security issue there is wrong", "change \"logic flaws\" to a different security issue",
                      "rename the bug section", "make the issues list bigger"])
    func namingAnIssueIsNotAskingForTheList(text: String) {
        #expect(!FallbackBrain.isIssueQuestion(text.lowercased()), "\(text)")
    }

    @Test func plainChatInfersNothing() {
        #expect(Intent.infer("hello there", hasElement: false) == nil)
    }

    @Test func oneTypoInAChangeVerb() {
        #expect(Intent.isChangeRequest("chanage the color"))
        #expect(Intent.isChangeRequest("cahnge the color"))
        #expect(!Intent.isChangeRequest("hde the footer"))  // too short to guess
        #expect(!Intent.isChangeRequest("the change looks good"))
        #expect(!Intent.isOneEditApart(Array("chaaange"), Array("change")))
    }

    @Test func fallbackSendsAColorChangeToCoderNotABugCard() {
        let site = BotSummary(id: UUID(), name: "hcr", instructions: "Website", state: .ready)
        let turn = FallbackBrain.turn(for: "change the green color to a white", speaker: site, bots: [site])
        guard case let .dispatch(crew, task)? = turn.action else { Issue.record("no dispatch"); return }
        #expect(crew == .coder)
        #expect(task == "change the green color to a white")
    }
}

@Suite(.serialized) @MainActor
struct PickedElementFlowTests {
    let element = PickedElement(label: "Start_a_Project", selector: "main > div.cta", tag: "div", url: "/pricing",
                                viewport: 683, left: 0, right: 0, width: 683, height: 220,
                                paddingLeft: "32px", paddingRight: "32px", marginLeft: "0px", marginRight: "0px", x: 0, y: 900)

    private func setUp() -> (BotStore, Bot, BotBrain, MockInspector) {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let inspector = MockInspector(nil)
        brain.pageInspector = inspector
        return (store, bot, brain, inspector)
    }

    private func messages(_ store: BotStore, _ bot: Bot) -> [ChatMessage] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    @Test func pickedElementPlusDescriptionDraftsABugWithTheSelector() async throws {
        let (store, bot, brain, inspector) = setUp()
        await brain.send("no gutter on the sides", in: .bot(bot.id), store: store, element: element)
        #expect(inspector.askedTerms.isEmpty)   // pointed at, so no searching
        let all = messages(store, bot)
        let user = try #require(all.first { $0.role == .user })
        #expect(user.content == "no gutter on the sides\n📍 Start_a_Project · /pricing · 683px")
        #expect(user.intentRaw == "bug")
        let card = try #require(all.last { $0.kind == .bugCard })
        let draft = try JSONDecoder().decode(BugDraft.self, from: Data(card.content.utf8))
        #expect(draft.selector == "main > div.cta")
        #expect(draft.body.contains("2. Look at `main > div.cta`"))
        #expect(draft.facts.first?.hasPrefix("The Start_a_Project box (div) is 0px from the left edge") == true)
    }

    @Test func fixPrefixDispatchesToCoderWithTheSelector() async {
        let (store, bot, brain, _) = setUp()
        await brain.send("fix: add a side gutter", in: .bot(bot.id), store: store, element: element)
        #expect(bot.runs?.first?.crew == .coder)
        #expect(bot.runs?.first?.task == "add a side gutter (`main > div.cta` on /pricing)")
    }

    @Test func askNeverProposesWork() async {
        let (store, bot, brain, _) = setUp()
        await brain.send("ask: fix the crash bugs in the footer", in: .bot(bot.id), store: store)
        #expect(bot.runs?.isEmpty ?? true)
        #expect(!(store.conversation(for: .bot(bot.id)).messages ?? []).contains { $0.kind == .actionCard })
    }

    @Test func reinterpretingAMessageAnswersAgainUnderTheNewIntent() async throws {
        let (store, bot, brain, _) = setUp()
        await brain.send("ask: the border has no padding", in: .bot(bot.id), store: store)
        let user = try #require(messages(store, bot).first { $0.role == .user })
        #expect(user.intentRaw == "ask")
        await brain.reinterpret(user, as: .bug, store: store)
        #expect(user.intentRaw == "bug")
        #expect(messages(store, bot).contains { $0.kind == .bugCard })
    }

    @Test func bugPrefixInTheLeadThreadPointsToTheBot() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        await brain.send("bug: the footer overlaps", in: .lead, store: store)
        let reply = (store.conversation(for: .lead).messages ?? []).last { $0.role == .assistant }?.content
        #expect(reply == "Open the bot for that project to report bugs or send work to its crew.")
    }
}

struct IssueReferenceTests {
    @Test(arguments: [
        ("ok fix https://github.com/kstrat2001/hcr/issues/8", 8),
        ("fix #12 please", 12),
        ("can you fix issue #3?", 3),
        ("fix 8", 8),
        ("please fix issue 12", 12),
    ])
    func issueNumbers(text: String, number: Int) {
        #expect(Intent.issueNumber(in: text) == number)
        #expect(Intent.infer(text, hasElement: false) == .fix)
    }

    @Test func noIssueReference() {
        #expect(Intent.issueNumber(in: "fix the footer") == nil)
    }

    @Test func draftHasExpectedAndAScreenshotSlotButNoDuplicateActual() {
        var draft = BugReport.draft(from: "no gutter on the sides", facts: nil, page: nil, repo: "o/r")
        #expect(draft.body.contains("_Describe what you expected._"))
        draft.expected = "The box keeps a side gutter at narrow widths."
        #expect(draft.body.contains("**Expected**\nThe box keeps a side gutter at narrow widths."))
        #expect(!draft.body.contains("**Actual**"))
        #expect(draft.body.contains("**Screenshot:** paste below."))
    }
}

@Suite(.serialized) @MainActor
struct FixIssueFlowTests {
    @Test func fixWithAnIssueLinkDispatchesThatIssueByTitle() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        var eight = issue(8, "No padding on left/right of the border")
        eight.body = "1. Open /pricing at 681px wide"
        brain.github = MockGitHub(issues: [eight])
        await brain.send("ok fix https://github.com/kstrat2001/hcr/issues/8", in: .bot(bot.id), store: store)
        #expect(bot.runs?.first?.task == "Fix #8: No padding on left/right of the border (kstrat2001/hcr)")
        #expect(bot.runs?.first?.crew == .coder)
    }
}

struct PromptTrimmingTests {
    let speaker = BotSummary(id: UUID(), name: "humancodereader", instructions: String(repeating: "Website work. ", count: 40), state: .ready)
    var bots: [BotSummary] {
        [speaker] + (0..<30).map { BotSummary(id: UUID(), name: "Bot \($0)", instructions: String(repeating: "x", count: 300), state: .ready) }
    }

    @Test func fullInstructionsStayWellUnderTheOnDeviceBudget() {
        let text = BotBrain.instructions(for: "where should this run? which machine is free?", speaker: speaker,
                                         bots: bots, compact: false)
        // ~4K tokens shared with the tool schema, request and answer: keep
        // instructions under ~2,600 characters (~650 tokens).
        #expect(text.count < 2600)
        #expect(!text.contains("Machines:"), "no sample fleet")
        #expect(text.contains("can't see the darkmux fleet yet"))
    }

    @Test func compactRetryDropsTheRoster() {
        let text = BotBrain.instructions(for: "which machine is free?", speaker: speaker, bots: bots, compact: true)
        #expect(!text.contains("Other bots"))
        #expect(text.count < 800)
    }
}

struct CorrectionTests {
    @Test(arguments: [
        ("no, it's a question", Intent.ask),
        ("not a bug, just asking", .ask),
        ("no, it's a bug", .bug),
        ("actually, fix it", .fix),
        ("nope, I meant review it", .review),
    ])
    func corrections(text: String, intent: Intent) {
        #expect(Intent.correction(in: text) == intent)
    }

    @Test func ordinaryMessagesAreNotCorrections() {
        #expect(Intent.correction(in: "the footer has no padding") == nil)
        #expect(Intent.correction(in: "now fix the header too, and make the footer match the new spacing everywhere please") == nil)
    }
}

@Suite(.serialized) @MainActor
struct CorrectionFlowTests {
    @Test func noItsAQuestionCancelsTheProposedRunAndAnswersInstead() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        await brain.send("fix: why does the pricing box touch the edges", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        #expect(run.phase == .proposed)
        await brain.send("no, it's a question", in: .bot(bot.id), store: store)
        #expect(run.phase == .canceled)
        let first = try #require((store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.role == .user }.min { $0.timestamp < $1.timestamp })
        #expect(first.intentRaw == "ask")
        #expect(bot.runs?.count == 1)
    }
}

struct PreviewViewportTests {
    @Test func fitUsesThePanelAsIs() {
        let l = PreviewViewport.fit.layout(in: CGSize(width: 683, height: 900))
        #expect(l.width == 683 && l.height == 900 && l.scale == 1)
    }

    @Test func desktopRendersAt1440AndScalesDownToFit() {
        let l = PreviewViewport.desktop.layout(in: CGSize(width: 720, height: 900))
        #expect(l.width == 1440)
        #expect(l.scale == 0.5)
        #expect(l.height == 1800)   // fills the panel's height after scaling
    }

    @Test func phoneFitsWithoutScalingInAWidePanel() {
        let l = PreviewViewport.phone.layout(in: CGSize(width: 1200, height: 900))
        #expect(l.width == 390 && l.scale == 1 && l.height == 844)   // a phone's height, centered (PreviewDeviceTests)
    }

    @Test func recipeViewportsPickTheDefault() {
        #expect(PreviewViewport.preferred(from: ["desktop", "phone"]) == .desktop)
        #expect(PreviewViewport.preferred(from: ["tablet"]) == .tablet)
        #expect(PreviewViewport.preferred(from: nil) == .fit)
    }
}

struct BriefTests {
    @Test func workBriefAddsRulesThatStopBlindSearchLoops() {
        let text = RunCoordinator.workBrief("Fix #8")
        #expect(text.hasPrefix("Fix #8"))
        #expect(text.contains("stop and say what you searched instead of repeating searches"))
    }
}

@Suite(.serialized) @MainActor
struct FixBriefFlowTests {
    @Test func fixIssueRunsCarryTheIssueBodyAsTheBrief() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: [GitHubIssue(number: 8, title: "No padding", body: "Open /pricing; selector `main > div`")])
        brain.runs.recipes.recipes["kstrat2001/hcr"] = .ready(PreviewManifest(command: "npm run dev", pageFile: "inertia/pages/{page}.tsx"), fromLocalCopy: false)
        await brain.send("fix #8", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        #expect(run.task == "Fix #8: No padding (kstrat2001/hcr)")
        #expect(run.brief?.contains("Element: main > div") == true)
        #expect(run.brief?.contains("Likely file: inertia/pages/pricing.tsx") == true)
    }
}

/// One preview action, "Chat about this": the pick is a chip, and what you
/// type decides what happens (a change is work, a visual problem is measured
/// into a bug card, a question is answered).
@Suite(.serialized) @MainActor
struct ChatAboutThisTests {
    private func setUp() -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/site", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.pageInspector = MockInspector(nil)
        return (store, bot, brain)
    }

    private func messages(_ store: BotStore, _ bot: Bot) -> [ChatMessage] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    /// One chat action; Edit (a hand edit, darkmux #3533) is the only other
    /// button, and only where the Mac app turns it on.
    @Test func thePickerOffersExactlyOneChatAction() {
        let script = BugReport.pageScript
        #expect(script.contains("'Chat about this'"))
        #expect(!script.contains("Ask about this"))
        #expect(!script.contains("Report a bug here"))
        #expect(script.components(separatedBy: "document.createElement('button')").count == 3, "Chat about this, and Edit")
        #expect(script.contains("if (window.__muxCanEdit) {"), "Edit only where the app turns it on")
        #expect(!script.contains("intent"), "the page never decides the intent")
    }

    @Test func aChangeProposesWork() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("make this bigger", in: .bot(bot.id), store: store, element: .fixture)
        let run = try #require(bot.runs?.first)
        #expect(run.crew == .coder)
        #expect(run.phase == .proposed)
        #expect(run.task.contains("`main > section.hero > h1`"))
        #expect(!messages(store, bot).contains { $0.kind == .bugCard })
    }

    @Test func aChangeToSelectedTextNamesTheText() async throws {
        let (store, bot, brain) = setUp()
        var element = PickedElement.fixture
        element.selectedText = "hello@example.com"
        await brain.send("replace this with kain@example.com", in: .bot(bot.id), store: store, element: element)
        let run = try #require(bot.runs?.first)
        #expect(run.task.contains("“hello@example.com”"), "Coder knows which text: \(run.task)")
    }

    @Test func aVisualProblemIsMeasuredIntoABugCard() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("why is this cut off", in: .bot(bot.id), store: store, element: .fixture)
        #expect(messages(store, bot).contains { $0.kind == .bugCard })
        #expect(bot.runs?.isEmpty ?? true)
    }

    @Test func aQuestionIsAnswered() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("what font is this", in: .bot(bot.id), store: store, element: .fixture)
        let all = messages(store, bot)
        #expect(all.last?.role == .assistant)
        #expect(!all.contains { $0.kind == .bugCard })
        #expect(!all.contains { $0.kind == .actionCard })
        #expect(bot.runs?.isEmpty ?? true)
    }
}
