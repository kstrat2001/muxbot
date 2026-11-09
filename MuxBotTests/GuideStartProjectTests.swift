import Foundation
import Testing
@testable import MuxBot

/// "new project" in Mux Bot's thread opens the Start chooser (or a named
/// template's form), with template names from the registry; the lead bot
/// never improvises; Start a project is always one tap away.
struct GuideStartProjectRouteTests {
    private let registry = [
        TemplateEntry(id: "website", repo: "kstrat2001/muxbot-template-site", ref: String(repeating: "a", count: 40), title: "Build a website", icon: "globe"),
        TemplateEntry(id: "book", repo: "kstrat2001/muxbot-template-book", ref: String(repeating: "b", count: 40), title: "Write a book", icon: "book.closed"),
    ]

    @Test(arguments: ["new project", "Start a project", "start something", "let's make a new project", "create a project"])
    func startPhrasesOpenTheChooser(text: String) {
        #expect(GuideRoute.route(text, templates: registry) == .startProject(template: nil), "\(text)")
    }

    @Test(arguments: [("new site", "website"), ("make a website", "website"), ("build a site", "website"),
                      ("new book", "book"), ("write a book", "book"), ("start a new book project", "book"),
                      ("book", "book"), ("website", "website")])
    func aNamedTemplateOpensItsForm(text: String, template: String) {
        #expect(GuideRoute.route(text, templates: registry) == .startProject(template: template), "\(text)")
    }

    @Test(arguments: ["how do I start a project?", "what is the book template?", "how does a new project get its repo?"])
    func questionsAboutStartingStillGoToHelp(text: String) {
        #expect(GuideRoute.route(text, templates: registry) == .help, "\(text)")
    }

    @Test func templateNamesComeFromTheRegistry() {
        let recipes = [TemplateEntry(id: "recipes", repo: "someone/muxbot-template-recipes", ref: String(repeating: "c", count: 40), title: "Collect recipes", icon: "fork.knife")]
        #expect(GuideRoute.route("new recipes project", templates: recipes) == .startProject(template: "recipes"))
        #expect(GuideRoute.route("new book", templates: recipes) == .startProject(template: nil), "no book in this registry")
    }

    @Test func otherRoutesAreUnchanged() {
        #expect(GuideRoute.route("check my setup", templates: registry) == .setup)
        #expect(GuideRoute.route("point me at a repo", templates: registry) == .firstBot(resource: nil))
        #expect(GuideRoute.route("change a setting", templates: registry) == .settingsOverview)
    }

    @Test func mux_botsChipsStayWhileYouType() {
        #expect(ChatShortcuts.showsRow(draft: "new pro", tweaking: false, picked: false, waitingCard: false, lead: true))
        #expect(!ChatShortcuts.showsRow(draft: "", tweaking: false, picked: false, waitingCard: true, lead: true), "hidden only while a card waits")
        #expect(!ChatShortcuts.showsRow(draft: "fix", tweaking: false, picked: false, waitingCard: false), "other bots as before")
    }

    @Test func theIntroLeadsWithStartingAProject() {
        #expect(LeadGuide.intro.contains("start a project"))
        #expect(!LeadGuide.intro.contains("first bot from a repo"))
        #expect(LeadGuide.menuText.contains("start a project") && LeadGuide.menuText.contains("check your setup")
                && LeadGuide.menuText.contains("change a setting") && LeadGuide.menuText.contains("how something works"))
    }
}

@Suite(.serialized) @MainActor
struct GuideStartProjectFlowTests {
    private func setUp() -> (BotStore, BotBrain, Recorder) {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let opened = Recorder()
        brain.openStart = { opened.add($0 ?? "chooser") }
        return (store, brain, opened)
    }

    private func replies(_ store: BotStore) -> [String] {
        (store.conversation(for: .lead).messages ?? []).filter { $0.role == .assistant }.map(\.content)
    }

    @Test func newProjectOpensTheChooser() async {
        let (store, brain, opened) = setUp()
        await brain.send("new project", in: .lead, store: store)
        #expect(opened.values == ["chooser"])
    }

    @Test func aNamedTemplateOpensItsForm() async {
        let (store, brain, opened) = setUp()
        await brain.send("write a book", in: .lead, store: store)
        #expect(opened.values == ["book"])
    }

    @Test func noRouteGetsThePlainMenuNotAnImprovisedAnswer() async {
        let (store, brain, opened) = setUp()
        await brain.send("tell me a joke", in: .lead, store: store)
        #expect(replies(store).last == LeadGuide.menuText)
        #expect(opened.values.isEmpty)
    }

    @Test func aHandOffStillWorks() async {
        let (store, brain, _) = setUp()
        let bot = store.add(name: "hcr", instructions: "Site")
        await brain.send("hcr should fix the header", in: .lead, store: store)
        let card = (store.conversation(for: .lead).messages ?? []).first { $0.kind == .actionCard }
        #expect(card != nil, "the hand-off card is still offered")
        #expect(replies(store).last != LeadGuide.menuText)
        _ = bot
    }

    @Test func aNewBotByNameStillWorks() async {
        let (store, brain, _) = setUp()
        await brain.send("new bot called recipes", in: .lead, store: store)
        #expect((store.conversation(for: .lead).messages ?? []).contains { $0.kind == .actionCard })
    }
}
