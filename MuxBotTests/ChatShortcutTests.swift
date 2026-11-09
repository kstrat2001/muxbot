import Foundation
import Testing
@testable import MuxBot

/// Shortcut chips above the chat bar: the core things you do in a thread,
/// one tap away. A chip sends its message at once (the bot answers, or
/// proposes work behind its Approve card) or opens a view; it never fills
/// the bar. Chips come from data: the guide and the bot's skills.
struct ChatShortcutTests {
    @Test func muxBotsThreadOffersAProjectSetupSettingsAndHelp() {
        let chips = ChatShortcuts.lead()
        #expect(chips.map(\.title) == ["Start a project", "Check my setup", "Change a setting", "How does this work?"])
        #expect(chips[0].action == .startProject)
    }

    @Test func aTemplateBotOffersItsSkillsThenItsPreview() {
        let chips = ChatShortcuts.bot(.init(hasRepo: false, canPreview: true, skills: ["Add a page", "Change the look"]))
        #expect(chips.map(\.title) == ["Add a page", "Change the look", "Show preview", "Point at something"])
        #expect(chips[0].action == .send("Add a page"))
        #expect(chips[2].action == .showPreview && chips[3].action == .pick)
    }

    @Test func aHandMadeBotWithARepoOffersItsIssues() {
        let chips = ChatShortcuts.bot(.init(hasRepo: true, canPreview: false, skills: []))
        #expect(chips.map(\.title) == ["Open issues", "Fix an issue"])
        let none = ChatShortcuts.bot(.init(hasRepo: false, canPreview: false, skills: []))
        #expect(none.isEmpty, "nothing it can do from a chip")
    }

    @Test func theRowHidesWhileYouTypeOrACardWaits() {
        #expect(ChatShortcuts.showsRow(draft: "", tweaking: false, picked: false, waitingCard: false))
        #expect(!ChatShortcuts.showsRow(draft: "fix", tweaking: false, picked: false, waitingCard: false))
        #expect(!ChatShortcuts.showsRow(draft: "", tweaking: false, picked: false, waitingCard: true))
        #expect(!ChatShortcuts.showsRow(draft: "", tweaking: true, picked: false, waitingCard: false))
    }

    /// Each lead chip's message is understood the way its label says.
    @Test func leadChipsRouteWhereTheirLabelsSay() {
        func sent(_ title: String) -> String? {
            if case let .send(text)? = ChatShortcuts.lead().first(where: { $0.title == title })?.action { return text }
            return nil
        }
        #expect(sent("Check my setup").flatMap(GuideRoute.route) == .setup)
        #expect(sent("Change a setting").flatMap(GuideRoute.route) == .settingsOverview)
        #expect(sent("How does this work?").flatMap(GuideRoute.route) == .help)
        #expect(sent("How does this work?").map { !HelpLibrary.bundled.search($0).isEmpty } == true, "the help covers it")
        let bot = ChatShortcuts.bot(.init(hasRepo: true, canPreview: false, skills: []))
        if case let .send(issues)? = bot.first(where: { $0.title == "Open issues" })?.action {
            #expect(Intent.infer(issues, hasElement: false) == .issues)
        } else { Issue.record("no Open issues chip") }
        if case let .send(fix)? = bot.first(where: { $0.title == "Fix an issue" })?.action {
            #expect(Intent.infer(fix, hasElement: false) == .issues)
        } else { Issue.record("no Fix an issue chip") }
    }

    @Test func aSkillsQuestionUsesItsExampleAsk() {
        let skill = BotSkill(name: "Add a page", body: "When: someone wants a new page. \"Add an About page\", \"a pricing page\".")
        #expect(skill.question == "Add a page: what exactly? For example, “Add an About page”.")
        #expect(BotSkill(name: "Tidy", body: "When: anything.").question == "Tidy: what exactly should I do?")
    }
}

@Suite(.serialized) @MainActor
struct ChatShortcutRunTests {
    private func userMessages(_ store: BotStore, _ chat: ChatContext) -> [String] {
        (store.conversation(for: chat).messages ?? []).filter { $0.role == .user }.map(\.content)
    }

    @Test func aChipSendsExactlyOneMessage() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.runs.profileSource = { [] }
        let router = AppRouter()
        let chip = ChatShortcuts.lead()[1]   // Check my setup
        await ChatShortcuts.run(chip, in: .lead, brain: brain, store: store, router: router, preview: nil)
        #expect(userMessages(store, .lead) == ["Check my setup"])
        let card = (store.conversation(for: .lead).messages ?? []).first { $0.kind == .guideCard }
        #expect(card?.guideCard == .setup)
    }

    @Test func aViewChipSendsNothing() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let router = AppRouter()
        await ChatShortcuts.run(ChatShortcuts.lead()[0], in: .lead, brain: brain, store: store, router: router, preview: nil)
        #expect(router.showStartProject)
        #expect(userMessages(store, .lead).isEmpty)
    }

    @Test func aSkillChipAsksOneQuestionAndTheAnswerIsTheRun() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.runs.profileSource = { [] }
        let bot = store.add(name: "Bakery", instructions: "Site")
        bot.skills = [BotSkill(name: "Add a page", body: "When: a new page. \"Add an About page\".\n\nFiles: src/pages/.")]
        let router = AppRouter()
        let chip = ChatShortcuts.bot(.init(hasRepo: false, canPreview: false, skills: ["Add a page"]))[0]
        await ChatShortcuts.run(chip, in: .bot(bot.id), brain: brain, store: store, router: router, preview: nil)
        #expect(userMessages(store, .bot(bot.id)) == ["Add a page"])
        let asked = (store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.role == .assistant }.last?.content
        #expect(asked == "Add a page: what exactly? For example, “Add an About page”.")
        #expect((bot.runs ?? []).isEmpty, "nothing proposed until it knows what")
        await brain.send("An About page with our story", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        #expect(run.task == "Add a page")
        #expect(run.phase == .proposed, "still behind its Approve card")
        #expect(run.brief?.contains("Add a page: An About page with our story") == true)
    }

    @Test func changeASettingShowsTheSwitches() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.runs.settingsStore = ModelSettingsStore(backing: MemoryBacking())
        await brain.send("Change a setting", in: .lead, store: store)
        let cards = (store.conversation(for: .lead).messages ?? []).compactMap(\.guideCard)
        #expect(cards == [.setting(.modelMode), .setting(.notifications)], "app settings; darkmux's only once paired")
    }
}
