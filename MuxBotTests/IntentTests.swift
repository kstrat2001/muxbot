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
        ("make it bigger", true, .bug),
        ("what is this font?", true, .ask),
    ])
    func inference(text: String, hasElement: Bool, intent: Intent) {
        #expect(Intent.infer(text, hasElement: hasElement) == intent)
    }

    @Test func plainChatInfersNothing() {
        #expect(Intent.infer("hello there", hasElement: false) == nil)
    }
}

@Suite(.serialized) @MainActor
struct PickedElementFlowTests {
    let element = PickedElement(label: "Start_a_Project", selector: "main > div.cta", tag: "div", url: "/pricing",
                                viewport: 683, left: 0, right: 0, width: 683, height: 220,
                                paddingLeft: "32px", paddingRight: "32px", marginLeft: "0px", marginRight: "0px", x: 0, y: 900)

    private func setUp() -> (BotStore, Bot, BotBrain, MockInspector) {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
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
        #expect(brain.pending == nil)
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
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: [issue(8, "No padding on left/right of the border")])
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
                                         bots: bots, fleet: .sample, compact: false)
        // ~4K tokens shared with the tool schema, request and answer: keep
        // instructions under ~2,600 characters (~650 tokens).
        #expect(text.count < 2600)
        #expect(text.contains("Machines:"))
    }

    @Test func fleetBriefingOnlyWhenAsked() {
        let text = BotBrain.instructions(for: "fix the footer", speaker: speaker, bots: bots, fleet: .sample, compact: false)
        #expect(!text.contains("Machines:"))
    }

    @Test func compactRetryDropsRosterAndFleet() {
        let text = BotBrain.instructions(for: "which machine is free?", speaker: speaker, bots: bots, fleet: .sample, compact: true)
        #expect(!text.contains("Other bots"))
        #expect(!text.contains("Machines:"))
        #expect(text.count < 700)
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
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
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
        #expect(l.width == 390 && l.scale == 1 && l.height == 900)
    }

    @Test func recipeViewportsPickTheDefault() {
        #expect(PreviewViewport.preferred(from: ["desktop", "phone"]) == .desktop)
        #expect(PreviewViewport.preferred(from: ["tablet"]) == .tablet)
        #expect(PreviewViewport.preferred(from: nil) == .fit)
    }
}
