import Foundation
import Testing
@testable import MuxBot

/// The first ten minutes (the MVP UX review): the first run writes itself
/// from the start-a-project answers, the bot greets you in its own words
/// (not its persona), the "feel" examples are tappable, a template bot
/// whose project isn't made says where it's made, Home with no bots opens
/// on the chooser, and setup is one copyable block.
struct FirstRunPlaybookTests {
    static let firstRun = """


        ## First run

        Make {name} the site for {purpose}.
        Make it feel {feel}: set the colors and fonts to match.
        Rewrite the headline and intro on the home page for it, in plain words.
        """

    @Test func theFirstRunSectionIsReadAndFilledIn() throws {
        let playbook = try Playbook.parse(PlaybookParserTests.website + Self.firstRun)
        let task = playbook.firstRunTask(name: "Bakery", purpose: "a small bakery in Leeds.", feel: "warm and friendly")
        #expect(task == "Make Bakery the site for a small bakery in Leeds. Make it feel warm and friendly: set the colors and fonts to match. Rewrite the headline and intro on the home page for it, in plain words.")
    }

    @Test func aLineWhoseAnswerIsBlankIsLeftOut() throws {
        let playbook = try Playbook.parse(PlaybookParserTests.website + Self.firstRun)
        let task = playbook.firstRunTask(name: "Bakery", purpose: "a small bakery", feel: "  ")
        #expect(task == "Make Bakery the site for a small bakery. Rewrite the headline and intro on the home page for it, in plain words.")
    }

    @Test func noFirstRunSectionMeansNoFirstRun() throws {
        let playbook = try Playbook.parse(PlaybookParserTests.website)
        #expect(playbook.firstRunTask(name: "Bakery", purpose: "a bakery", feel: "warm") == nil)
    }

    @Test func aFirstRunWithOnlyBlankAnswersIsNoFirstRun() throws {
        let playbook = try Playbook.parse(PlaybookParserTests.website + "\n\n## First run\n\nMake it about {purpose}.\n")
        #expect(playbook.firstRunTask(name: "Bakery", purpose: "", feel: "") == nil)
    }

    @Test func theBundledWebsitePlaybookHasAFirstRun() throws {
        let playbook = try #require(TemplateRegistry.bundledPlaybook(for: "website"))
        #expect(playbook.firstRunTask(name: "Acme", purpose: "a bakery", feel: "warm")?.contains("Acme") == true)
    }
}

/// A question's trailing "(For example: a, b, c.)" or "(a, b, c.)" becomes
/// tappable suggestions; the label keeps only the question.
struct QuestionSuggestionTests {
    @Test func theFeelExamplesBecomeSuggestions() {
        let q = PlaybookQuestion("How should it feel? (For example: calm and minimal, bold and colorful, warm and friendly.)")
        #expect(q.label == "How should it feel?")
        #expect(q.suggestions == ["calm and minimal", "bold and colorful", "warm and friendly"])
    }

    @Test func aPlainListBecomesSuggestionsToo() {
        let q = PlaybookQuestion("What is it for, in a sentence? (A portfolio, a small business, an event, a project.)")
        #expect(q.label == "What is it for, in a sentence?")
        #expect(q.suggestions == ["a portfolio", "a small business", "an event", "a project"])
    }

    @Test func aQuestionWithNoExamplesHasNone() {
        let q = PlaybookQuestion("What's the site called?")
        #expect(q.label == "What's the site called?")
        #expect(q.suggestions.isEmpty)
    }

    @Test func tappingASuggestionFillsOrAdds() {
        #expect(PlaybookQuestion.adding("warm and friendly", to: "") == "warm and friendly")
        #expect(PlaybookQuestion.adding("bold and colorful", to: "warm and friendly") == "warm and friendly, bold and colorful")
        #expect(PlaybookQuestion.adding("warm and friendly", to: "warm and friendly") == "warm and friendly", "never twice")
    }

    @Test func startNeedsANameAndWhatItsFor() {
        #expect(!StartProject.Answers(name: "Bakery").canStart)
        #expect(!StartProject.Answers(name: " ", purpose: "a bakery").canStart)
        #expect(StartProject.Answers(name: "Bakery", purpose: "a bakery").canStart)
    }
}

/// The bot's first message is said to you, never its persona (which is
/// addressed to the model).
struct GreetingTests {
    @Test func aPersonaIsNeverReadOut() {
        let text = BotGreeting.text(name: "Acme", about: "You look after Acme, a website.\n\nYou make the change that was asked for.", hasPreview: true)
        #expect(!text.contains("You look after"))
        #expect(text.hasPrefix("Hi, I'm Acme."))
        #expect(text.contains("point at something in the preview"))
    }

    @Test func whatYouWroteAboutABotIsKept() {
        let text = BotGreeting.text(name: "hcr", about: "Keeps humancodereader.com healthy", hasPreview: false)
        #expect(text == "Hi, I'm hcr. Keeps humancodereader.com healthy. Tell me what needs doing; nothing runs until you approve it.")
    }

    @Test func noAboutStillGreets() {
        #expect(BotGreeting.text(name: "Docs", about: "", hasPreview: false)
            == "Hi, I'm Docs. Tell me what needs doing; nothing runs until you approve it.")
    }

    @Test func aStartedProjectGreetsThenOffersItsFirstRun() {
        let text = BotGreeting.started(name: "Bakery", hasFirstRun: true)
        #expect(text.hasPrefix("Hi, I'm Bakery."))
        #expect(text.contains("Approve"))
        #expect(!BotGreeting.started(name: "Bakery", hasFirstRun: false).contains("Approve"))
    }
}

@Suite(.serialized) @MainActor
struct FirstRunFlowTests {
    @Test func startingAProjectPostsAGreetingThenTheFirstRunCard() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let playbook = try Playbook.parse(PlaybookParserTests.website + FirstRunPlaybookTests.firstRun)
        brain.runs.workspaceMaker = { _ in DarkmuxClient.Workspace(workspace: "bakery-1a2b", branch: "main", created: true) }
        let bot = await StartProject.start(TemplateRegistryTests.entry, playbook: playbook,
                                           answers: StartProject.Answers(name: "Bakery", purpose: "a small bakery", style: "warm and friendly"),
                                           store: store, runs: brain.runs)
        // The greeting, then the card ("Work copy ready" follows from darkmux).
        let messages = (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }
        #expect(messages.map(\.kind).prefix(2) == [.text, .dispatchCard])
        #expect(messages.first?.role == .assistant)
        #expect(messages.first?.content.hasPrefix("Hi, I'm Bakery.") == true)
        #expect(messages.first?.content.contains("You look after") == false)
        #expect(messages.filter { $0.kind == .dispatchCard }.count == 1)
        let run = try #require(bot.runs?.first)
        #expect(run.phase == .proposed, "nothing runs until Approve")
        #expect(run.crew == .coder)
        #expect(run.task.hasPrefix("Make Bakery the site for a small bakery."))
    }

    @Test func noFirstRunSectionPostsOnlyTheGreeting() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let playbook = try Playbook.parse(PlaybookParserTests.website)
        brain.runs.workspaceMaker = { _ in DarkmuxClient.Workspace(workspace: "bakery-1a2b", branch: "main", created: true) }
        let bot = await StartProject.start(TemplateRegistryTests.entry, playbook: playbook,
                                           answers: StartProject.Answers(name: "Bakery", purpose: "a bakery"),
                                           store: store, runs: brain.runs)
        let messages = (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }
        #expect(messages.first?.content == "Hi, I'm Bakery. Tell me what to change, or point at something in the preview.")
        #expect(!messages.contains { $0.kind == .dispatchCard })
        #expect(bot.runs?.isEmpty ?? true)
    }
}

/// A template bot whose project isn't made on this Mac (made while
/// unpaired, or on iPhone) says where it's made and offers to make it,
/// never "add a folder or a GitHub repo".
@Suite(.serialized) @MainActor
struct TemplateProjectBlockerTests {
    private func templateBot(_ store: BotStore) -> Bot {
        let bot = store.add(name: "Bakery", instructions: "")
        bot.useCaseId = "website"
        return bot
    }

    @Test func onThisMacItOffersToMakeTheProject() {
        let store = TestStore.fresh()
        let bot = templateBot(store)
        let blocker = RunBlocker.check(paired: true, crew: .coder, bot: bot, deviceRuns: true)
        #expect(blocker == .projectNotMade("Bakery", here: true))
        #expect(blocker?.message.contains("folder") == false)
    }

    @Test func onAPhoneItSaysTheProjectIsMadeOnTheMac() {
        let store = TestStore.fresh()
        let bot = templateBot(store)
        let blocker = RunBlocker.check(paired: false, crew: .coder, bot: bot, deviceRuns: false)
        #expect(blocker == .projectNotMade("Bakery", here: false))
        #expect(blocker?.message.contains("Mac") == true)
        #expect(blocker?.message.contains("paired") == true)
    }

    @Test func unpairedOnTheMacPairingComesFirst() {
        let store = TestStore.fresh()
        #expect(RunBlocker.check(paired: false, crew: .coder, bot: templateBot(store), deviceRuns: true) == .unpaired)
    }

    @Test func aBotWithNoCodeAndNoTemplateStillAsksForCode() {
        let store = TestStore.fresh()
        let bot = store.add(name: "Notes", instructions: "")
        #expect(RunBlocker.check(paired: true, crew: .coder, bot: bot, deviceRuns: true) == .noCode)
    }

    @Test func makingTheProjectUsesTheBotsTemplate() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = templateBot(store)
        var asked: DarkmuxClient.WorkspaceBody?
        brain.runs.templateSource = { id in id == "website" ? TemplateRegistryTests.entry : nil }
        brain.runs.workspaceMaker = { body in
            asked = body
            return DarkmuxClient.Workspace(workspace: "bakery-9", branch: "main", created: true)
        }
        await brain.runs.setUpWorkCopy(for: bot, store: store)
        #expect(asked?.template == true)
        #expect(asked?.ref == TemplateRegistryTests.entry.ref)
        #expect(bot.workspaceName == "bakery-9")
    }

    @Test func anUnknownTemplateSaysSo() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = templateBot(store)
        brain.runs.templateSource = { _ in nil }
        brain.runs.workspaceMaker = { _ in Issue.record("nothing to make it from"); throw CancellationError() }
        await brain.runs.setUpWorkCopy(for: bot, store: store)
        guard case let .failed(why)? = brain.runs.workCopySetup[bot.id] else { Issue.record("should fail"); return }
        #expect(why.contains("template"))
    }
}

/// Home with no bots opens on "What do you want to get done?", and a
/// successful pairing with no bots goes straight back to it.
@Suite(.serialized) @MainActor
struct StartFirstTests {
    @Test func theSidebarOpensOnTheChooserWithNoBots() {
        let router = AppRouter()
        router.usesSidebar = true
        router.openOnStart(botCount: 0)
        #expect(router.sidebar == nil)
        let busy = AppRouter()
        busy.usesSidebar = true
        busy.openOnStart(botCount: 2)
        #expect(busy.sidebar == .lead)
    }

    @Test func pairingWithNoBotsContinuesIntoStartAProject() {
        let router = AppRouter()
        router.usesSidebar = true
        router.sidebar = .lead
        router.continueAfterPairing(botCount: 0)
        #expect(router.sidebar == nil)

        let phone = AppRouter()
        phone.tab = .activity
        phone.path = [.lead]
        phone.continueAfterPairing(botCount: 0)
        #expect(phone.tab == .bots)
        #expect(phone.path.isEmpty)
    }

    @Test func pairingWithBotsStaysPut() {
        let router = AppRouter()
        router.usesSidebar = true
        router.sidebar = .activity
        router.continueAfterPairing(botCount: 1)
        #expect(router.sidebar == .activity)
    }
}

// The Terminal install block is gone (Kain's rule: no commands in the app);
// each step has its own button or official page (NoCommandsTests,
// SetupDetectionTests).
