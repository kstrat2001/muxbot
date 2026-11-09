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

    @Test func aPlaybookWithoutATitleIsRefused() {
        #expect(throws: Playbook.ParseError.missing("title")) { try Playbook.parse("icon: globe\n\n## Persona\n\nHi") }
    }

    @Test func unknownValuesFallBackInsteadOfBreaking() throws {
        let p = try Playbook.parse("title: X\nanimal: dragon\ncolors: red, 12345g\ncrew: wizard, reviewer\n")
        #expect(p.animal == nil, "not one of the app's animals")
        #expect(p.bodyHex == nil && p.eyeHex == nil, "not hex colors")
        #expect(p.crew == [.reviewer], "unknown crew dropped")
        #expect(p.skills.isEmpty && p.questions.isEmpty)
        #expect(try Playbook.parse("title: X\n").crew == [.coder], "Coder by default")
    }

    @Test func aSkillWithNoNameOrBodyIsSkipped() throws {
        let p = try Playbook.parse("title: X\n\n## Skill:\n\nbody\n\n## Skill: Empty\n\n## Skill: Real\n\nWhen: always.\n")
        #expect(p.skills.map(\.name) == ["Real"])
    }

    @Test func anOversizedFileIsRefused() {
        let big = "title: X\n" + String(repeating: "a", count: Playbook.maxBytes)
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
        {"version":1,"templates":[
          {"id":"website","repo":"kstrat2001/muxbot-template-vite-react","ref":"v1.0.0","title":"Build a website","icon":"globe"},
          {"id":"loose","repo":"someone/thing","ref":"main","title":"Loose","icon":"star"},
          {"id":"bad","repo":"not a repo","ref":"v1","title":"Bad","icon":"star"}
        ]}
        """#
        let entries = try TemplateRegistry.decode(Data(json.utf8))
        #expect(entries.map(\.id) == ["website"], "a branch isn't pinned; a repo must be owner/name")
    }

    @Test func offlineItUsesTheCacheThenTheBuiltInCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("templates.json")
        let offline = TemplateRegistry(cacheURL: cache) { _ in throw Offline() }
        let builtIn = await offline.templates()
        #expect(builtIn.map(\.id) == ["website"], "the copy built into the app")
        #expect(builtIn.first?.ref == "v1.0.0")

        let online = TemplateRegistry(cacheURL: cache) { _ in
            Data(#"{"version":1,"templates":[{"id":"docs","repo":"a/b","ref":"v2.0.0","title":"Write docs","icon":"book"}]}"#.utf8)
        }
        #expect(await online.templates().map(\.id) == ["docs"])
        let laterOffline = TemplateRegistry(cacheURL: cache) { _ in throw Offline() }
        #expect(await laterOffline.templates().map(\.id) == ["docs"], "the last list fetched")
    }

    @Test func playbooksAreFetchedAtTheirPinnedRef() async throws {
        let seen = URLRecorder()
        let registry = TemplateRegistry(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { url in
            seen.add(url)
            return Data("title: Fetched\n".utf8)
        }
        let entry = TemplateEntry(id: "website", repo: "kstrat2001/muxbot-template-vite-react", ref: "v1.0.0", title: "Build a website", icon: "globe")
        let p = try #require(await registry.playbook(for: entry))
        #expect(p.title == "Fetched")
        #expect(seen.urls.last?.absoluteString == "https://raw.githubusercontent.com/kstrat2001/muxbot-template-vite-react/v1.0.0/PLAYBOOK.md")
    }

    @Test func aPlaybookThatWontParseFallsBackToTheBuiltInOne() async throws {
        let registry = TemplateRegistry(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) { _ in
            Data("no title here".utf8)
        }
        let entry = TemplateEntry(id: "website", repo: "kstrat2001/muxbot-template-vite-react", ref: "v1.0.0", title: "Build a website", icon: "globe")
        #expect(await registry.playbook(for: entry)?.title == "Build a website")
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
        let entry = TemplateEntry(id: "website", repo: "kstrat2001/muxbot-template-vite-react", ref: "v1.0.0", title: "Build a website", icon: "globe")
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
        #expect(bot.look == BotLook(animal: .fox, bodyHex: "0e9f8e", eyeHex: "ffffff"))
        #expect(bot.instructions.hasPrefix("You look after Bakery, a website built with Vite."))
        #expect(bot.instructions.contains("A small bakery's site"))
        #expect(bot.instructions.contains("Warm and friendly"))
        #expect(bot.repoSlugs.isEmpty, "local only until GitHub")
        #expect(asked?.template == true)
        #expect(asked?.repoURL == "https://github.com/kstrat2001/muxbot-template-vite-react")
        #expect(asked?.ref == "v1.0.0")
        #expect(bot.workspaceName == "bakery-1a2b")
    }

    @Test func theFlowReadsOnlyTheEntryAndItsPlaybook() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let playbook = try Playbook.parse("title: Write docs\nicon: book\nanimal: owl\ncrew: researcher\n\n## Persona\n\nYou write {name}.\n")
        let entry = TemplateEntry(id: "docs", repo: "a/docs-template", ref: "v2.0.0", title: "Write docs", icon: "book")
        brain.runs.workspaceMaker = { _ in DarkmuxClient.Workspace(workspace: "manual-1", branch: "main", created: true) }
        let bot = await StartProject.start(entry, playbook: playbook, answers: StartProject.Answers(name: "Manual"),
                                           store: store, runs: brain.runs)
        #expect(bot.useCaseId == "docs")
        #expect(bot.look.animal == .owl)
        #expect(bot.instructions == "You write Manual.")
    }
}
