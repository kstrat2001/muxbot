import Foundation
import Testing
@testable import MuxBot

/// A PLAYBOOK.md for a project that has none: schema 1 with its structure
/// fixed in code, the persona and conventions drafted on device (or the
/// general ones), editable, written only as a new file after Approve, and
/// added to the bot's next PR.
@MainActor
struct PlaybookSetupFileTests {
    @Test func theGeneralOneIsAValidSchemaOnePlaybook() throws {
        let setup = PlaybookSetup.general(name: "Darkly Energized", purpose: "my consulting site", folderName: "darklyenergized")
        let playbook = try #require(setup.parsed)
        #expect(playbook.title == "Darkly Energized")
        #expect(playbook.pitch == "my consulting site")
        #expect(playbook.skills.map(\.name).contains("Fix a bug"))
        #expect(playbook.persona.contains("Darkly Energized"))
        #expect(!setup.drafted)
    }

    @Test func theDraftOnlyChangesTheProse() throws {
        let general = PlaybookSetup.general(name: "DE", purpose: "site", folderName: "de")
        let drafted = general.withDraft(persona: "You look after DE, an AdonisJS app.", conventions: "Pages are in inertia/pages/.")
        #expect(drafted.drafted)
        let playbook = try #require(drafted.parsed)
        #expect(playbook.persona == "You look after DE, an AdonisJS app.")
        #expect(playbook.skills.map(\.name) == general.skills.map(\.name), "the same skills, in the same order")
        #expect(playbook.skills.allSatisfy { $0.body.hasSuffix("Files and conventions: Pages are in inertia/pages/.") })
        #expect(general.withDraft(persona: " ", conventions: "").drafted == false)
    }

    @Test func proseCantBreakTheFile() throws {
        var setup = PlaybookSetup.general(name: "Two\nlines", purpose: "a site\nschema: 2", folderName: "x")
        setup.persona = "You look after it.\n## Skill: Sneaky\n\nNot a skill."
        let playbook = try #require(setup.parsed, "still parses: \(setup.markdown)")
        #expect(playbook.title == "Two lines")
        #expect(!playbook.skills.map(\.name).contains("Sneaky"))
        #expect(playbook.persona.contains("### Skill: Sneaky"))
    }

    @Test func withoutAPersonaOrSkillsItCantBeApproved() {
        var setup = PlaybookSetup.general(name: "DE", purpose: "site", folderName: "de")
        setup.persona = "  "
        #expect(setup.parsed == nil)
        setup = PlaybookSetup.general(name: "DE", purpose: "site", folderName: "de")
        setup.skills = []
        #expect(setup.parsed == nil)
    }

    @Test func itsWrittenOnlyAsANewFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("playbook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let setup = PlaybookSetup.general(name: "DE", purpose: "site", folderName: "de")
        try PreviewSetup.writeNew(setup.data, at: PlaybookSetup.path, into: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("PLAYBOOK.md")) == setup.data)
        #expect(throws: PreviewSetup.WriteError.exists) { try PreviewSetup.writeNew(Data("x".utf8), at: PlaybookSetup.path, into: dir) }
        #expect(throws: PreviewSetup.WriteError.self) { try PreviewSetup.writeNew(Data("x".utf8), at: "../escape.md", into: dir) }
    }
}

@Suite(.serialized) @MainActor
struct PlaybookSetupOfferTests {
    private func bot(_ store: BotStore) -> Bot {
        let bot = store.add(name: "DE", instructions: "")
        bot.folderName = "darklyenergized"
        return bot
    }

    private func brain(checkout: URL?, files: Set<String> = ["package.json"], readme: String? = "# DE\nAdonisJS + Inertia.",
                       draft: (persona: String, conventions: String)? = nil) -> BotBrain {
        let brain = BotBrain()
        brain.checkoutFolder = { _ in checkout }
        brain.checkoutReader = { _ in (nil, files) }
        brain.readmeReader = { _ in readme }
        brain.playbookDrafter = { _, _, _ in draft }
        return brain
    }

    private func cards(_ store: BotStore, _ bot: Bot) -> [ChatMessage] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.kind == .actionCard }
    }

    @Test func aCheckoutWithoutOneGetsOneCardOnce() async {
        let store = TestStore.fresh()
        let b = bot(store)
        let brain = brain(checkout: URL(fileURLWithPath: "/tmp/de"), draft: ("You look after DE, an AdonisJS app.", "Pages are in inertia/pages/."))
        await brain.offerPlaybookSetup(for: b, purpose: "my site", store: store)
        await brain.offerPlaybookSetup(for: b, purpose: "my site", store: store)
        let cards = cards(store, b)
        #expect(cards.count == 1)
        guard case let .setUpPlaybook(setup)? = cards.first?.action else { Issue.record("no card"); return }
        #expect(setup.drafted)
        #expect(setup.persona == "You look after DE, an AdonisJS app.")
        #expect(cards.first?.actionState == .waiting)
    }

    @Test func withoutTheModelItOffersTheGeneralOne() async {
        let store = TestStore.fresh()
        let b = bot(store)
        await brain(checkout: URL(fileURLWithPath: "/tmp/de"), draft: nil).offerPlaybookSetup(for: b, purpose: "my site", store: store)
        guard case let .setUpPlaybook(setup)? = cards(store, b).first?.action else { Issue.record("no card"); return }
        #expect(!setup.drafted)
        #expect(setup.skills.map(\.name).contains("Fix a bug"))
    }

    @Test func aCheckoutThatHasOneOrACloneGetsNoCard() async {
        let store = TestStore.fresh()
        let has = bot(store)
        await brain(checkout: URL(fileURLWithPath: "/tmp/de"), files: ["PLAYBOOK.md"]).offerPlaybookSetup(for: has, purpose: "x", store: store)
        #expect(cards(store, has).isEmpty, "never over the project's own")
        let clone = bot(store)
        await brain(checkout: nil).offerPlaybookSetup(for: clone, purpose: "x", store: store)
        #expect(cards(store, clone).isEmpty, "nowhere to write it")
    }

    @Test func approvingUsesItsSkillsAndKeepsTheFileForThePR() async throws {
        let store = TestStore.fresh()
        let b = bot(store)
        let brain = brain(checkout: URL(fileURLWithPath: "/tmp/de"), draft: ("You look after DE, an AdonisJS app.", ""))
        await brain.offerPlaybookSetup(for: b, purpose: "my site", store: store)
        let card = try #require(cards(store, b).first)
        guard case let .setUpPlaybook(setup)? = card.action else { Issue.record("no card"); return }
        brain.resolve(card, approve: true, store: store)
        #expect(LocalBotState.shared[b.id]?.prFiles?[PlaybookSetup.path] == setup.data)
        #expect(b.skills == setup.parsed?.skills)
        #expect(b.instructions.hasPrefix("You look after DE, an AdonisJS app."))
        #expect(b.instructions.contains("my site"))
    }
}
