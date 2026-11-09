import Foundation
import Testing
@testable import MuxBot

/// Template schema 2: `.darkmux/preview.json` is darkmux's own recipe
/// (`schema_version` "1.0", darkmux's keys only), and the app's hints
/// (page_file, pages, viewports, conventions) live in PLAYBOOK.md.
struct TemplateSchema2Tests {
    static let playbook2 = """
        schema: 2
        title: Build a website
        icon: globe
        pitch: A site.
        page_file: src/pages/{page}.tsx
        pages: /, /about
        viewports: desktop, phone

        ## Questions

        - What's the site called?

        ## Persona

        You look after {name}.

        ## Conventions

        Vite + React. Each page is a component in src/pages/.

        ## Skill: Add a page

        When: a new page.
        """

    static let darkmuxRecipe = Data(#"{"schema_version":"1.0","command":"npm run dev","env":{"PORT":"{port}"},"ready":{"http":"/"},"install":{"command":"npm ci","unless_exists":"node_modules"}}"#.utf8)

    @Test func aSchemaTwoPlaybookCarriesTheHints() throws {
        let p = try Playbook.parse(Self.playbook2)
        #expect(p.hints == RepoHints(conventions: "Vite + React. Each page is a component in src/pages/.",
                                     pageFile: "src/pages/{page}.tsx", pages: ["/", "/about"], viewports: ["desktop", "phone"]))
    }

    @Test func aSchemaOnePlaybookHasNoHintKeys() {
        let one = Self.playbook2.replacingOccurrences(of: "schema: 2", with: "schema: 1")
        #expect(throws: Playbook.ParseError.unknownKey("page_file", closest: "title")) { try Playbook.parse(one) }
        let plain = one.replacingOccurrences(of: "page_file: src/pages/{page}.tsx\npages: /, /about\nviewports: desktop, phone\n", with: "")
        #expect((try? Playbook.parse(plain))?.hints.conventions == nil, "a schema 1 playbook's sections stay as they were")
    }

    @Test func schemaThreeIsNewer() {
        let three = Self.playbook2.replacingOccurrences(of: "schema: 2", with: "schema: 3")
        #expect(throws: Playbook.ParseError.newerSchema(3)) { try Playbook.parse(three) }
    }

    @Test func darkmuxsRecipeIsATemplatesPreview() throws {
        try TemplateSchema.checkPreview(Self.darkmuxRecipe)
    }

    @Test func darkmuxsRecipeIsCheckedLikeDarkmuxDoes() {
        let file = ".darkmux/preview.json"
        #expect(throws: TemplateSchema.Problem.unknownKey(file: file, key: "conventions", closest: "command")) {
            try TemplateSchema.checkPreview(Data(#"{"schema_version":"1.0","command":"npm run dev","conventions":"x"}"#.utf8))
        }
        #expect(throws: TemplateSchema.Problem.self) {
            try TemplateSchema.checkPreview(Data(#"{"schema_version":"2.0","command":"npm run dev"}"#.utf8))
        }
        #expect(throws: TemplateSchema.Problem.self, "a template has no checkout to copy files from") {
            try TemplateSchema.checkPreview(Data(#"{"schema_version":"1.0","command":"npm run dev","env_from_source":[".env"]}"#.utf8))
        }
    }

    @Test func aSchemaTwoTemplateNeedsDarkmuxsRecipe() {
        let legacy = Data(#"{"schema":1,"command":"npm run dev","conventions":"x"}"#.utf8)
        guard case .refused = TemplateRegistry.check(playbook: Data(Self.playbook2.utf8), preview: legacy) else {
            Issue.record("a schema 2 playbook with the old preview.json should be refused"); return
        }
        guard case .ready = TemplateRegistry.check(playbook: Data(Self.playbook2.utf8), preview: Self.darkmuxRecipe) else {
            Issue.record("schema 2 should be ready"); return
        }
    }

    @Test func theBuiltInTemplatesAreSchemaTwoWithTheirHints() throws {
        for id in ["website", "book"] {
            let files = try #require(TemplateRegistry.bundledFiles(for: id))
            let playbook = try #require(TemplateRegistry.check(playbook: files.playbook, preview: files.preview).playbook, "\(id) is ready")
            #expect(playbook.schema == 2)
            #expect(playbook.hints.pageFile != nil)
            #expect(playbook.hints.conventions != nil)
            let recipe = try #require(try JSONSerialization.jsonObject(with: files.preview) as? [String: Any])
            #expect(recipe["schema_version"] as? String == "1.0")
            #expect((recipe["env"] as? [String: String])?["HOST"] == "0.0.0.0", "a container preview listens on every address")
        }
    }

    @Test func aRecipeAndTheHintsMakeOneManifest() throws {
        let recipe = try JSONDecoder().decode(PreviewManifest.self, from: Self.darkmuxRecipe)
        let merged = recipe.with(try Playbook.parse(Self.playbook2).hints)
        #expect(merged.command == "npm run dev")
        #expect(merged.pageFile == "src/pages/{page}.tsx")
        #expect(merged.conventions?.hasPrefix("Vite") == true)
        #expect(merged.viewports == ["desktop", "phone"])
    }
}

@Suite(.serialized) @MainActor
struct RecipeHintsTests {
    @Test func aTemplateBotsHintsComeFromItsTemplatesPlaybook() async throws {
        let store = RecipeStore()
        store.templatePlaybook = { id in id == "website" ? try? Playbook.parse(TemplateSchema2Tests.playbook2) : nil }
        await store.load(for: "workspace:site-1", workspace: nil, connection: nil, github: NoGitHub(), useCaseId: "website")
        let hints = try #require(store.hints["workspace:site-1"])
        #expect(hints.pageFile == "src/pages/{page}.tsx")
    }

    @Test func aReposHintsComeFromItsOwnPlaybook() async throws {
        let store = RecipeStore()
        let github = NoGitHub(files: ["PLAYBOOK.md": Data(TemplateSchema2Tests.playbook2.utf8),
                                      ".darkmux/preview.json": TemplateSchema2Tests.darkmuxRecipe])
        await store.load(for: "kain/site", workspace: nil, connection: nil, github: github)
        guard case let .ready(manifest, _)? = store.recipes["kain/site"] else { Issue.record("no recipe"); return }
        #expect(manifest.command == "npm run dev")
        #expect(store.hints["kain/site"]?.conventions?.hasPrefix("Vite") == true)
    }

    @Test func aBotsRecipeCarriesItsPlaybooksHints() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "Site", instructions: "")
        store.addResource(.repo, "https://github.com/kain/site", to: bot)
        let recipes = RecipeStore()
        let github = NoGitHub(files: ["PLAYBOOK.md": Data(TemplateSchema2Tests.playbook2.utf8),
                                      ".darkmux/preview.json": TemplateSchema2Tests.darkmuxRecipe])
        await recipes.load(for: "kain/site", workspace: nil, connection: nil, github: github)
        let recipe = try #require(recipes.recipe(for: bot))
        #expect(recipe.command == "npm run dev")
        #expect(recipe.pageFile == "src/pages/{page}.tsx", "what run briefs and bug reports use")
        #expect(RunCoordinator.workBrief("Fix it", recipe: recipe).contains("Each page is a component in src/pages/"))
    }

    @Test func theGeneratedPlaybookIsSchemaTwo() throws {
        let setup = PlaybookSetup.general(name: "DE", purpose: "site", folderName: "de")
        #expect(setup.markdown.contains("schema: 2"))
        #expect(setup.parsed != nil)
    }
}

/// A GitHub that answers only the files it's given.
struct NoGitHub: GitHubClient {
    var files: [String: Data] = [:]
    func openIssues(repo: String) async throws -> [GitHubIssue] { [] }
    func issue(repo: String, number: Int) async throws -> GitHubIssue? { nil }
    func file(repo: String, path: String) async throws -> Data? { files[path] }
    func pullRequest(repo: String, number: Int) async throws -> PullRequestInfo? { nil }
}
