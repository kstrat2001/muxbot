import Foundation
import Testing
@testable import MuxBot

/// "What do you want to get done?": a use case is a template repo with a
/// PLAYBOOK.md (the recipe for its bot) at a pinned ref, listed in the
/// GitHub template registry with a copy built into the app. Starting one
/// makes a bot from the playbook, copies its skills into it, and has
/// darkmux set up a local workspace from the template.
struct PlaybookParserTests {
    static let website = """
        # Playbook: a website

        schema: 1
        title: Build a website
        icon: globe
        pitch: A one-page site you can grow.
        animal: fox
        colors: 0e9f8e, ffffff
        crew: coder

        Some prose about the file.

        ## Questions

        - What's the site called?
        - What is it for, in a sentence?

        ## Persona

        You look after {name}, a website built with Vite.
        You make the change that was asked for.

        ## Skill: Add a page

        When: someone wants a new page. "Add an About page".

        Done when: the new path shows the page.

        ## Skill: Change the look

        When: different colors or fonts.

        Files and conventions:
        - Colors are the CSS variables at the top of `src/styles.css`.

        ## Notes

        Ignored.
        """

    @Test func theHeaderSectionsAndSkillsAreRead() throws {
        let p = try Playbook.parse(Self.website)
        #expect(p.title == "Build a website")
        #expect(p.icon == "globe")
        #expect(p.pitch == "A one-page site you can grow.")
        #expect(p.animal == .fox)
        #expect(p.bodyHex == "0e9f8e" && p.eyeHex == "ffffff")
        #expect(p.crew == [.coder])
        #expect(p.questions == ["What's the site called?", "What is it for, in a sentence?"])
        #expect(p.persona == "You look after {name}, a website built with Vite.\nYou make the change that was asked for.")
        #expect(p.skills.map(\.name) == ["Add a page", "Change the look"])
        #expect(p.skills[1].body.contains("src/styles.css"))
        #expect(!p.skills[1].body.contains("Ignored"), "an unknown section ends the skill and is skipped")
    }

    @Test func thePersonaNamesTheBot() throws {
        #expect(try Playbook.parse(Self.website).persona(for: "Bakery") == "You look after Bakery, a website built with Vite.\nYou make the change that was asked for.")
    }

    /// A minimal schema-1 playbook with `header` lines and `sections`.
    static func minimal(_ header: String = "", sections: String? = nil) -> String {
        "schema: 1\ntitle: X\nicon: star\npitch: P\n\(header)\n"
            + (sections ?? "## Questions\n\n- Name?\n\n## Persona\n\nYou are {name}.\n\n## Skill: Real\n\nWhen: always.\n")
    }

    @Test func aPlaybookWithoutATitleIsRefused() {
        let text = Self.minimal().replacingOccurrences(of: "title: X\n", with: "")
        #expect(throws: Playbook.ParseError.missing("title")) { try Playbook.parse(text) }
    }

    @Test func unknownValuesFallBackInsteadOfBreaking() throws {
        let p = try Playbook.parse(Self.minimal("animal: dragon\ncolors: red, 12345g\ncrew: wizard, reviewer"))
        #expect(p.animal == nil, "not one of the app's animals")
        #expect(p.bodyHex == nil && p.eyeHex == nil, "not hex colors")
        #expect(p.crew == [.reviewer], "unknown crew dropped")
        #expect(try Playbook.parse(Self.minimal()).crew == [.coder], "Coder by default")
    }

    @Test func aSkillWithNoNameOrBodyIsSkipped() throws {
        let p = try Playbook.parse(Self.minimal(sections: "## Questions\n\n- Name?\n\n## Persona\n\nHi\n\n## Skill:\n\nbody\n\n## Skill: Empty\n\n## Skill: Real\n\nWhen: always.\n"))
        #expect(p.skills.map(\.name) == ["Real"])
    }

    @Test func anOversizedFileIsRefused() {
        let big = Self.minimal() + String(repeating: "a", count: Playbook.maxBytes)
        #expect(throws: Playbook.ParseError.tooLarge) { try Playbook.parse(big) }
    }

    @Test func theBundledWebsitePlaybookParses() throws {
        let p = try #require(TemplateRegistry.bundledPlaybook(for: "website"))
        #expect(p.title == "Build a website")
        #expect(p.skills.count == 5)
    }
}

struct TemplateRegistryTests {
    struct Offline: Error {}

    @Test func theListDecodesAndSkipsUnpinnedEntries() throws {
        let json = #"""
        {"schema":1,"templates":[
          {"id":"website","repo":"kstrat2001/muxbot-template-site","ref":"1f1a5b5678e53642f702b0d176aaf2bbc8117f12","title":"Build a website","icon":"globe","summary":"A site."},
          {"id":"tagged","repo":"someone/thing","ref":"v1.0.0","title":"Tagged","icon":"star"},
          {"id":"loose","repo":"someone/thing","ref":"main","title":"Loose","icon":"star"},
          {"id":"bad","repo":"not a repo","ref":"1f1a5b5678e53642f702b0d176aaf2bbc8117f12","title":"Bad","icon":"star"},
          {"id":"extra","repo":"a/b","ref":"1f1a5b5678e53642f702b0d176aaf2bbc8117f12","title":"Extra","icon":"star","colour":"red"}
        ]}
        """#
        let entries = try TemplateRegistry.decode(Data(json.utf8))
        #expect(entries.map(\.id) == ["website"], "pinned to a commit SHA, owner/name, and only the schema's keys")
        #expect(entries.first?.summary == "A site.")
    }

    @Test func offlineItUsesTheCacheThenTheBuiltInCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("templates.json")
        let offline = TemplateRegistry(cacheURL: cache) { _ in throw Offline() }
        let builtIn = await offline.templates()
        #expect(builtIn.map(\.id) == ["website", "book"], "the copy built into the app")
        #expect(builtIn.allSatisfy { TemplateRegistry.isPinned($0.ref) })

        let online = TemplateRegistry(cacheURL: cache) { _ in
            Data(#"{"schema":1,"templates":[{"id":"docs","repo":"a/b","ref":"0123456789abcdef0123456789abcdef01234567","title":"Write docs","icon":"book"}]}"#.utf8)
        }
        #expect(await online.templates().map(\.id) == ["docs"])
        let laterOffline = TemplateRegistry(cacheURL: cache) { _ in throw Offline() }
        #expect(await laterOffline.templates().map(\.id) == ["docs"], "the last list fetched")
    }

    static let entry = TemplateEntry(id: "website", repo: "kstrat2001/muxbot-template-site",
                                     ref: "1f1a5b5678e53642f702b0d176aaf2bbc8117f12", title: "Build a website", icon: "globe")
    static let preview = Data(#"{"schema":1,"command":"npm run dev"}"#.utf8)

    @Test func templatesAreFetchedAtTheirPinnedCommit() async throws {
        let seen = URLRecorder()
        let registry = TemplateRegistry(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { url in
            seen.add(url)
            return url.lastPathComponent == "preview.json" ? Self.preview : Data(PlaybookParserTests.minimal().utf8)
        }
        let details = await registry.template(for: Self.entry)
        #expect(details.playbook?.title == "X")
        #expect(seen.urls.map(\.absoluteString) == [
            "https://raw.githubusercontent.com/kstrat2001/muxbot-template-site/1f1a5b5678e53642f702b0d176aaf2bbc8117f12/PLAYBOOK.md",
            "https://raw.githubusercontent.com/kstrat2001/muxbot-template-site/1f1a5b5678e53642f702b0d176aaf2bbc8117f12/.darkmux/preview.json",
        ])
    }

    @Test func aTemplateThatFailsTheSchemaIsRefusedNotGuessed() async {
        let registry = TemplateRegistry(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { url in
            url.lastPathComponent == "preview.json" ? Self.preview : Data("title: no schema here\n".utf8)
        }
        #expect(await registry.template(for: Self.entry) == .refused("This template's PLAYBOOK.md doesn't say which schema it follows."))
    }

    @Test func offlineTheBuiltInCopiesAreChecked() async throws {
        let registry = TemplateRegistry(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { _ in throw Offline() }
        // Only at the built-in copy's own pin (sweep 6b #19).
        let bundled = try #require(TemplateRegistry.bundledTemplates().first { $0.id == "website" })
        #expect(await registry.template(for: bundled).playbook?.title == "Build a website")
    }
}

final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [URL] = []
    func add(_ url: URL) { lock.withLock { seen.append(url) } }
    var urls: [URL] { lock.withLock { seen } }
}

struct BotSkillTests {
    let skills = try! Playbook.parse(StartProjectFixtures.playbookText).skills

    @Test func theSkillThatFitsGoesIntoTheBrief() {
        let picked = BotSkill.relevant(skills, to: "make the colors darker green")
        #expect(picked.first?.name == "Change the look")
        let brief = RunCoordinator.workBrief("make the colors darker green", skills: picked)
        #expect(brief.contains("How this kind of change is done here (Change the look):"))
        #expect(brief.contains("src/styles.css"))
    }

    @Test func nothingFitsNothingIsAdded() {
        #expect(BotSkill.relevant(skills, to: "what's the weather").isEmpty)
        #expect(!RunCoordinator.workBrief("x", skills: []).contains("How this kind"))
    }

    @Test func skillsRoundTripThroughTheBot() {
        let bot = Bot(name: "Bakery", instructions: "")
        bot.skills = skills
        #expect(bot.skills == skills)
        #expect(!bot.skillsJSON.isEmpty)
    }
}

enum StartProjectFixtures {
    static let playbookText = PlaybookParserTests.website
}

@Suite(.serialized) @MainActor
struct StartProjectFlowTests {
    @Test func startingAWebsiteMakesItsBotFromThePlaybook() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let playbook = try Playbook.parse(PlaybookParserTests.website)
        let entry = TemplateRegistryTests.entry
        var asked: DarkmuxClient.WorkspaceBody?
        brain.runs.workspaceMaker = { body in
            asked = body
            return DarkmuxClient.Workspace(workspace: "bakery-1a2b", branch: "main", created: true)
        }
        let bot = await StartProject.start(entry, playbook: playbook,
                                           answers: StartProject.Answers(name: "Bakery", purpose: "A small bakery's site", style: "Warm and friendly"),
                                           store: store, runs: brain.runs)
        #expect(bot.name == "Bakery")
        #expect(bot.useCaseId == "website")
        #expect(bot.skills.map(\.name) == ["Add a page", "Change the look"])
        #expect(bot.look.animal != .octopus, "a fresh look, not the template's fixed one (and never the lead bot's)")
        #expect(bot.instructions.hasPrefix("You look after Bakery, a website built with Vite."))
        #expect(bot.instructions.contains("A small bakery's site"))
        #expect(bot.instructions.contains("Warm and friendly"))
        #expect(bot.repoSlugs.isEmpty, "local only until GitHub")
        #expect(asked?.template == true)
        #expect(asked?.repoURL == "https://github.com/kstrat2001/muxbot-template-site")
        #expect(asked?.ref == "1f1a5b5678e53642f702b0d176aaf2bbc8117f12")
        #expect(bot.workspaceName == "bakery-1a2b")
    }

    @Test func theFlowReadsOnlyTheEntryAndItsPlaybook() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let playbook = try Playbook.parse("schema: 1\ntitle: Write docs\nicon: book\npitch: Docs.\nanimal: owl\ncrew: researcher\n\n## Questions\n\n- Name?\n\n## Persona\n\nYou write {name}.\n\n## Skill: Add a chapter\n\nWhen: a new chapter.\n")
        let entry = TemplateEntry(id: "docs", repo: "a/docs-template", ref: "0123456789abcdef0123456789abcdef01234567", title: "Write docs", icon: "book")
        brain.runs.workspaceMaker = { _ in DarkmuxClient.Workspace(workspace: "manual-1", branch: "main", created: true) }
        let bot = await StartProject.start(entry, playbook: playbook, answers: StartProject.Answers(name: "Manual"),
                                           store: store, runs: brain.runs)
        #expect(bot.useCaseId == "docs")
        #expect(bot.instructions == "You write Manual.")
    }
}

/// One versioned schema for templates.json, PLAYBOOK.md and preview.json:
/// schema 1 is read; a newer or missing one is refused by name, never
/// guessed at.
struct TemplateSchemaTests {
    @Test func schemaOneIsRead() throws {
        #expect(try Playbook.parse(PlaybookParserTests.minimal()).title == "X")
        try TemplateSchema.checkPreview(Data(#"{"schema":1,"command":"npm run dev","env":{"PORT":"{port}"},"ready":{"http":"/"}}"#.utf8))
        #expect(try TemplateRegistry.decode(Data(#"{"schema":1,"templates":[]}"#.utf8)).isEmpty)
    }

    @Test func aNewerSchemaIsRefusedByName() {
        let playbook = PlaybookParserTests.minimal().replacingOccurrences(of: "schema: 1", with: "schema: 4")
        #expect(throws: Playbook.ParseError.newerSchema(4)) { try Playbook.parse(playbook) }
        #expect(Playbook.ParseError.newerSchema(4).message.hasPrefix("This template needs a newer Mux Bot"))
        #expect(throws: TemplateSchema.Problem.newerSchema(file: ".darkmux/preview.json", 3)) {
            try TemplateSchema.checkPreview(Data(#"{"schema":3,"command":"x"}"#.utf8))
        }
        #expect(throws: TemplateSchema.Problem.newerSchema(file: "templates.json", 3)) {
            try TemplateRegistry.decode(Data(#"{"schema":3,"templates":[]}"#.utf8))
        }
    }

    @Test func aMissingSchemaIsRefused() {
        let playbook = PlaybookParserTests.minimal().replacingOccurrences(of: "schema: 1\n", with: "")
        #expect(throws: Playbook.ParseError.missing("schema")) { try Playbook.parse(playbook) }
        #expect(throws: TemplateSchema.Problem.missingSchema(file: ".darkmux/preview.json")) {
            try TemplateSchema.checkPreview(Data(#"{"command":"x"}"#.utf8))
        }
        #expect(throws: TemplateSchema.Problem.missingSchema(file: "templates.json")) {
            try TemplateRegistry.decode(Data(#"{"version":1,"templates":[]}"#.utf8).replacingVersion())
        }
    }

    @Test func anUnknownPreviewKeyIsRefusedWithTheClosestKey() {
        #expect(throws: TemplateSchema.Problem.unknownKey(file: ".darkmux/preview.json", key: "comand", closest: "command")) {
            try TemplateSchema.checkPreview(Data(#"{"schema":1,"comand":"npm run dev"}"#.utf8))
        }
        #expect(throws: Playbook.ParseError.unknownKey("pich", closest: "pitch")) {
            try Playbook.parse(PlaybookParserTests.minimal("pich: oops"))
        }
    }

    @Test func aPlaybookNeedsQuestionsAPersonaAndASkill() {
        for (section, missing) in [("Questions", "## Persona\n\nHi\n\n## Skill: S\n\nWhen: x.\n"),
                                   ("Persona", "## Questions\n\n- Q?\n\n## Skill: S\n\nWhen: x.\n"),
                                   ("Skill", "## Questions\n\n- Q?\n\n## Persona\n\nHi\n")] {
            #expect(throws: Playbook.ParseError.missingSection(section)) { try Playbook.parse(PlaybookParserTests.minimal(sections: missing)) }
        }
    }

    @Test func theBuiltInCopiesFollowSchemaOne() throws {
        let files = try #require(TemplateRegistry.bundledFiles(for: "website"))
        #expect(TemplateRegistry.check(playbook: files.playbook, preview: files.preview).playbook != nil)
        #expect(TemplateRegistry.bundledTemplates().map(\.id) == ["website", "book"])
    }
}

private extension Data {
    /// The list with its "version" key dropped (an old list with no schema).
    func replacingVersion() -> Data { Data(#"{"templates":[]}"#.utf8) }
}
