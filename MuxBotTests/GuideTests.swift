import Foundation
import Testing
@testable import MuxBot

/// Mux Bot, the lead bot, as a guide: setup check, first bot, help from the
/// bundled articles (saying when it doesn't know), and settings explained
/// with the live switch in the chat. He never starts work.
struct GuideRouteTests {
    @Test(arguments: ["check my setup", "Help me get started", "is everything ready?", "what do I need to set up?"])
    func setupPhrasesShowTheChecklist(text: String) {
        #expect(GuideRoute.route(text) == .setup)
    }

    @Test func aRepoLinkMakesTheFirstBot() {
        #expect(GuideRoute.route("make a bot for https://github.com/kstrat2001/hcr")
                == .firstBot(resource: "https://github.com/kstrat2001/hcr"))
        #expect(GuideRoute.route("point me at a repo") == .firstBot(resource: nil))
        #expect(GuideRoute.route("let's make my first bot") == .firstBot(resource: nil))
    }

    /// A path in a question is something to explain, not a folder to make a
    /// bot for.
    @Test(arguments: ["What does /client/profiles do?", "what is ~/Library/Containers for", "why does /Users/kain/hcr fail?"])
    func aPathInAQuestionIsHelp(text: String) {
        #expect(GuideRoute.route(text) == .help)
    }

    @Test func aFolderPathMakesTheFirstBotOnlyWhenItLooksLikeAFolder() {
        #expect(GuideRoute.route("make a bot for ~/code/hcr") == .firstBot(resource: "~/code/hcr"))
        #expect(GuideRoute.route("/Users/kain/code/hcr") == .firstBot(resource: "/Users/kain/code/hcr"))
        #expect(GuideRoute.route("/client/profiles") == nil, "an endpoint, not a folder")
        #expect(GuideRoute.route("can you make a bot for https://github.com/kstrat2001/hcr?")
                == .firstBot(resource: "https://github.com/kstrat2001/hcr"), "a repo link still works in a question")
    }

    @Test func settingsAreNamedByWhatTheyDo() {
        #expect(GuideRoute.route("switch the model choice to always ask") == .setting(.modelMode))
        #expect(GuideRoute.route("what does Always ask do?") == .setting(.modelMode))
        #expect(GuideRoute.route("turn off notifications") == .setting(.notifications))
        #expect(GuideRoute.route("which models can Mux Bot use?") == .setting(.darkmuxModels))
        #expect(GuideRoute.route("does it sync with iCloud?") == .setting(.sync))
    }

    @Test func questionsGoToTheHelp() {
        #expect(GuideRoute.route("how do I pair with darkmux?") == .help)
        #expect(GuideRoute.route("What is a bot") == .help)
    }

    @Test(arguments: ["fix #8", "what's running?", "hand this to hcr", "new bot called Life coach", "bug: the header overlaps"])
    func workAndStatusAreNotTheGuides(text: String) {
        #expect(GuideRoute.route(text) == nil)
    }
}

struct HelpRetrievalTests {
    let library = HelpLibrary.bundled

    @Test func theArticlesAreBundled() {
        let ids = Set(library.articles.map(\.id))
        for id in ["getting-started", "install-darkmux", "pairing", "models", "bots", "runs", "preview", "github", "sync", "mux-bot"] {
            #expect(ids.contains(id), "missing \(id)")
        }
        #expect(library.article("pairing")?.title == "Pairing with darkmux")
    }

    @Test(arguments: [
        ("how do I pair with darkmux", "pairing"),
        ("how do I install darkmux", "install-darkmux"),
        ("how do I undo a run", "runs"),
        ("what does loads when used mean", "models"),
        ("how do I open a pull request", "github"),
        ("how much RAM do I need", "install-darkmux"),
        ("why can't Mux Bot reach darkmux", "pairing"),
        ("what is a bot", "bots"),
    ])
    func aCoveredQuestionFindsItsArticle(question: String, article: String) throws {
        let hit = try #require(library.search(question).first, "nothing for \(question)")
        #expect(hit.article.id == article, "\(question) → \(hit.article.id) › \(hit.section)")
    }

    @Test(arguments: ["what's the weather in paris", "write me a poem about cats", "who won the world cup",
                      "tell me a joke", "what is the capital of france", "how do I bake bread", "what's the best pizza topping"])
    func anythingElseIsBelowTheThreshold(question: String) {
        #expect(library.search(question).isEmpty, "\(question) matched \(library.search(question).first.map { $0.article.id } ?? "")")
    }

    /// The threshold is word coverage, not the embedding: a fake embedder
    /// that rates everything alike changes the order, never what's known.
    @Test func theEmbeddingOnlyRanks() {
        struct Flat: SentenceEmbedder { func vector(for text: String) -> [Double]? { [1, 1, 1] } }
        let flat = HelpLibrary(articles: library.articles, embedder: Flat())
        #expect(flat.search("what's the weather in paris").isEmpty)
        #expect(flat.search("how do I pair with darkmux").first?.article.id == "pairing")
    }
}

struct SetupCheckTests {
    var fresh: SetupFacts { SetupFacts(platform: .mac, appleSilicon: true, memoryGB: 128) }

    @Test func theStepsGoInOrder() {
        // Optional rows (LM Studio, GitHub) come last.
        // One darkmux row (installed and its app connection are one thing to
        // the app); optional rows (LM Studio, GitHub) come last.
        // No Docker row (Kain, 2026-11-12); optional rows come last.
        #expect(SetupCheck.steps(fresh).map(\.id) == [.mac, .darkmux, .pair, .models, .lmStudio, .github])
    }

    @Test func aFreshMacWithNothingInstalled() {
        let steps = SetupCheck.steps(fresh)
        #expect(steps.state(.mac) == .done)
        #expect(steps.state(.darkmux) == .todo, "one row: install it or start it")
        #expect(steps[.darkmux]?.link == DarkmuxLinks.guide, "darkmux's guide, never a command")
        #expect(steps.state(.pair) == .later, "pairing waits for darkmux")
        // Before pairing the app can't see darkmux's engines: it waits for pairing.
        #expect(steps.state(.models) == .later)
    }

    @Test func theAppConnectionAnsweringMeansDarkmuxIsInstalled() {
        var facts = fresh; facts.endpointUp = true
        let steps = SetupCheck.steps(facts)
        #expect(steps.state(.darkmux) == .done)
        #expect(steps.state(.pair) == .todo)
    }

    @Test func lmStudioNeedsAModel() {
        var facts = fresh
        facts.lmStudio = .notAnswering
        // Installed but not serving (where the app can't look, it's unknown).
        facts.lmStudioApp = .installed
        // Optional: not done is shown as optional, never a to-do.
        #expect(SetupCheck.steps(facts).state(.lmStudio) == .optional)
        facts.lmStudio = .models(0)
        let empty = SetupCheck.steps(facts)
        #expect(empty.state(.lmStudio) == .optional)
        #expect(empty[.lmStudio]?.detail.contains("128 GB") == true)
        facts.lmStudio = .models(3)
        #expect(SetupCheck.steps(facts).state(.lmStudio) == .done)
    }

    @Test func pairedWithModelsRunning() {
        var facts = fresh
        facts.endpointUp = true; facts.lmStudio = .models(2); facts.paired = true
        facts.listing = .listed; facts.listedModels = 4; facts.runningModels = 2
        facts.githubSignedIn = true
        let steps = SetupCheck.steps(facts)
        #expect(steps.allSatisfy { $0.state == .done }, "\(steps.map { "\($0.id) \($0.state)" })")
        #expect(SetupCheck.summary(steps) == "All set")
    }

    /// GitHub is optional: it's never in "N of M done", so a working setup
    /// without it is "All set" (Kain saw "5 of 8" with two steps left).
    @Test func theCountLeavesOutOptionalGitHub() {
        var facts = fresh
        facts.endpointUp = true; facts.lmStudio = .models(16)
        #expect(SetupCheck.summary(SetupCheck.steps(facts)) == "2 of 4 done", "pairing and models still to go")
        facts.paired = true; facts.listing = .listed; facts.listedModels = 4; facts.runningModels = 2
        #expect(SetupCheck.summary(SetupCheck.steps(facts)) == "All set", "signed out of GitHub, still all set")
        facts.githubSignedIn = true
        #expect(SetupCheck.summary(SetupCheck.steps(facts)) == "All set")
    }

    /// LM Studio is one engine of several (Flint, TensorFold): optional,
    /// still detected, never in the count (Kain, 2026-11-11).
    @Test func lmStudioIsOptional() {
        var facts = fresh
        facts.endpointUp = true; facts.lmStudioApp = .notInstalled; facts.lmStudio = .notAnswering
        facts.paired = true; facts.listing = .listed; facts.listedModels = 1; facts.runningModels = 1
        let steps = SetupCheck.steps(facts)
        #expect(steps[.lmStudio]?.title == "LM Studio (optional)")
        #expect(steps[.lmStudio]?.linkTitle == "Get LM Studio")
        #expect(SetupCheck.summary(steps) == "All set", "a model from another engine is enough")
    }

    /// No model yet: the required step says darkmux needs a model engine
    /// and links darkmux's guide, before pairing or after.
    @Test func noModelSaysToSetUpAnEngine() {
        var facts = fresh
        // With no engine, the step suggests one for this Mac (#103).
        let line = EngineRecommendation.for(facts).line
        facts.endpointUp = true; facts.lmStudioApp = .notInstalled; facts.lmStudio = .notAnswering
        // Before pairing the app can't see darkmux's engines (Flint or
        // TensorFold may be there): it waits, and says where to look if not.
        var models = SetupCheck.steps(facts)[.models]
        #expect(models?.state == .later)
        #expect(models?.detail == "After pairing, this checks darkmux's models. No model engine yet? darkmux's guide shows how (Flint, TensorFold or LM Studio).")
        #expect(models?.link == DarkmuxLinks.models)
        facts.paired = true; facts.listing = .listed; facts.listedModels = 0; facts.runningModels = 0
        models = SetupCheck.steps(facts)[.models]
        #expect(models?.state == .todo)
        #expect(models?.detail == line)
        #expect(models?.link == DarkmuxLinks.models)
        facts.listedModels = 3
        models = SetupCheck.steps(facts)[.models]
        #expect(models?.detail.contains("Flint, TensorFold or LM Studio") == true, "listed but none answer: start an engine")
        #expect(models?.link == DarkmuxLinks.models)
    }

    /// LM Studio already has models: pairing is all that's left for models.
    @Test func lmStudioWithModelsWaitsForPairing() {
        var facts = fresh
        facts.endpointUp = true; facts.lmStudio = .models(16)
        #expect(SetupCheck.steps(facts)[.models]?.state == .later)
    }

    /// Optional rows not done look optional, never like a to-do.
    @Test func optionalRowsAreNeverToDos() {
        var facts = fresh
        facts.lmStudioApp = .notInstalled; facts.lmStudio = .notAnswering
        let steps = SetupCheck.steps(facts)
        #expect(steps.state(.lmStudio) == .optional)
        #expect(steps.state(.github) == .optional)
    }

    /// darkmux not answering: one row, plain words, darkmux's guide.
    @Test func darkmuxIsOneRow() {
        let steps = SetupCheck.steps(fresh)
        #expect(steps[.darkmux]?.title == "darkmux")
        #expect(steps[.darkmux]?.detail == "darkmux isn't answering on this Mac. Install it or start it; darkmux's guide shows both.")
        #expect(steps[.pair]?.detail == "After darkmux is running.")
    }

    @Test func aFailedListingSaysWhy() {
        var facts = fresh
        facts.endpointUp = true; facts.paired = true; facts.listing = .failed("The request timed out.")
        let steps = SetupCheck.steps(facts)
        #expect(steps.state(.models) == .todo)
        #expect(steps[.models]?.detail.contains("The request timed out.") == true)
    }

    @Test func aPhoneNeedsAMac() {
        let steps = SetupCheck.steps(SetupFacts(platform: .phone, appleSilicon: false, memoryGB: 8))
        #expect(steps.state(.mac) == .needsMac)
        #expect(steps.filter { $0.id != .mac && $0.id != .github }.allSatisfy { $0.state == .later })
    }

    @Test func anIntelMacIsSaid() {
        let steps = SetupCheck.steps(SetupFacts(platform: .mac, appleSilicon: false, memoryGB: 32))
        #expect(steps.state(.mac) == .todo)
    }

    @Test(arguments: [(128, "96 GB or more"), (64, "33 to 64 GB"), (48, "33 to 64 GB"), (16, "32 GB or less")])
    func modelsSizedToThisMac(gb: Int, tier: String) {
        #expect(SetupCheck.memoryTier(gb: gb) == tier)
    }
}

/// The live setup checklist looks once when it appears, then every few
/// seconds while it's the newest (not twice at the start).
@Suite @MainActor
struct SetupWatchTests {
    @Test(.timeLimit(.minutes(1))) func itProbesOnceThenWaits() async throws {
        var probes = 0
        var shown: [Int] = []
        let watch = Task { @MainActor in
            await SetupProbe.watch(isLive: true, every: .seconds(3600), probe: { probes += 1; return probes }, show: { shown.append($0) })
        }
        for _ in 0..<100 where probes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(probes == 1)
        #expect(shown == [1])
        watch.cancel()
        await watch.value
    }

    @Test func anOldChecklistLooksOnceAndStops() async {
        var probes = 0
        await SetupProbe.watch(isLive: false, every: .seconds(3600), probe: { probes += 1; return probes }, show: { _ in })
        #expect(probes == 1)
    }
}

@Suite(.serialized) @MainActor
struct LeadGuideFlowTests {
    private func setUp() -> (BotStore, BotBrain) {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.runs.settingsStore = ModelSettingsStore(backing: MemoryBacking())
        brain.runs.profileSource = { [] }
        return (store, brain)
    }

    private func lastGuideCard(_ store: BotStore) -> GuideCard? {
        (store.conversation(for: .lead).messages ?? []).sorted { $0.timestamp < $1.timestamp }
            .last { $0.kind == .guideCard }?.guideCard
    }

    @Test func setupShowsTheLiveChecklist() async {
        let (store, brain) = setUp()
        await brain.send("check my setup", in: .lead, store: store)
        #expect(lastGuideCard(store) == .setup)
    }

    @Test func aRepoLinkBecomesANewBotOnApprove() async throws {
        let (store, brain) = setUp()
        await brain.send("make a bot for https://github.com/kstrat2001/hcr", in: .lead, store: store)
        let card = try #require((store.conversation(for: .lead).messages ?? []).first { $0.kind == .actionCard })
        guard case let .createBot(draft)? = card.action else { Issue.record("no createBot"); return }
        #expect(draft.name == "hcr")
        #expect(draft.resource == "https://github.com/kstrat2001/hcr")
        #expect(store.allBots().isEmpty, "nothing until Approve")
        brain.github = MockGitHub()
        brain.resolve(card, approve: true, store: store)
        // Set up like Work on a project I already have (sweep 6b #18).
        await brain.creatingBot?.value
        let bot = try #require(store.allBots().first)
        #expect(bot.name == "hcr")
        #expect(bot.repoSlugs == ["kstrat2001/hcr"])
    }

    /// Folders come only from Add folder (a security-scoped bookmark, kept on
    /// this Mac): a pasted path never becomes a synced resource.
    @Test func aFolderPathGoesToNewBotNotACard() async throws {
        let (store, brain) = setUp()
        await brain.send("make a bot for /Users/kain/code/hcr", in: .lead, store: store)
        let messages = store.conversation(for: .lead).messages ?? []
        #expect(!messages.contains { $0.kind == .actionCard }, "no createBot card with a path")
        #expect(lastGuideCard(store) == .firstBot)
        // One way in (New): the folder goes through Work on a project I already have.
        #expect(messages.contains { $0.role == .assistant && $0.content.contains("Work on a project I already have") })
        #expect(store.allBots().isEmpty)
    }

    @Test func noLinkYetOffersNewBot() async {
        let (store, brain) = setUp()
        await brain.send("point me at a repo", in: .lead, store: store)
        #expect(lastGuideCard(store) == .firstBot)
    }

    @Test func aQuestionTheHelpCoversIsAnsweredWithItsArticle() async throws {
        let (store, brain) = setUp()
        await brain.send("how do I pair with darkmux?", in: .lead, store: store)
        guard case let .answer(text, articles, onDevice)? = lastGuideCard(store) else { Issue.record("no answer card"); return }
        #expect(articles.first == "pairing")
        #expect(!onDevice, "no model here: the article itself")
        #expect(text.contains("Pair with darkmux"))
        #expect(NoCommands.says(text) == nil, "no command to run in help")
    }

    @Test func aQuestionItDoesntCoverIsADontKnow() async throws {
        let (store, brain) = setUp()
        await brain.send("what's the capital of France?", in: .lead, store: store)
        let last = try #require((store.conversation(for: .lead).messages ?? []).max { $0.timestamp < $1.timestamp })
        #expect(last.kind == .text)
        #expect(last.content.hasPrefix("I don't know"))
    }

    @Test func aSettingIsExplainedWithItsSwitchAndNothingChangesYet() async {
        let (store, brain) = setUp()
        await brain.send("switch the model choice to always ask", in: .lead, store: store)
        #expect(lastGuideCard(store) == .setting(.modelMode))
        #expect(brain.runs.currentModelSettings().mode == .auto, "flipping the switch is the approval")
    }

    @Test func theSwitchWritesTheLiveSetting() {
        let (_, brain) = setUp()
        // Saved only for a machine darkmux has named (sweep 7 #2).
        brain.runs.machine = DarkmuxClient.Machine(id: "m-1", name: "studio")
        GuideSettings.setModelMode(.ask, runs: brain.runs)
        #expect(brain.runs.currentModelSettings().mode == .ask)
        #expect(GuideSettings.describe(.ask) == "Always ask")
    }

    @Test func aDarkmuxSettingWaitsForPairing() async throws {
        let (store, brain) = setUp()
        await brain.send("which models can Mux Bot use?", in: .lead, store: store)
        #expect(lastGuideCard(store) == nil, "no darkmux switch before pairing")
        let last = try #require((store.conversation(for: .lead).messages ?? []).max { $0.timestamp < $1.timestamp })
        #expect(last.content.contains("Pair Mux Bot"))
    }

    @Test func theLeadBotIsAGuide() {
        #expect(LeadBot.persona.contains("set up"))
        #expect(LeadBot.persona.contains("don't know"))
        #expect(!LeadBot.persona.contains("orchestrate"))
    }
}

struct WhoamiDecodeTests {
    @Test func anyLocalOrAList() throws {
        let local = try JSONDecoder().decode(DarkmuxClient.Whoami.self, from: Data(#"{"client_name":"Mux Bot","scopes":{"profiles":"local","workspace":true}}"#.utf8))
        #expect(local.profiles == nil)
        let listed = try JSONDecoder().decode(DarkmuxClient.Whoami.self, from: Data(#"{"client_name":"Mux Bot","scopes":{"profiles":["flint-rec"],"workspace":true}}"#.utf8))
        #expect(listed.profiles == ["flint-rec"])
    }
}
