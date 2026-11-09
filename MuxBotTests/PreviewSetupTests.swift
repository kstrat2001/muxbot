import Foundation
import Testing
@testable import MuxBot

/// Setting up a missing preview recipe: worked out by rules, offered on an
/// Approve card, written exactly as approved into your checkout (never over
/// one that exists), and added to the bot's next PR.
struct PreviewSetupFileTests {
    private static let adonis = ProjectSetupDetector.detect(
        packageJSON: #"{"scripts":{"dev":"node ace serve --hmr"}}"#, files: ["package-lock.json", ".env.example"])

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func theFileIsDarkmuxsRecipeShapeAndNothingElse() throws {
        let data = try #require(PreviewSetup(Self.adonis, folderName: "site").recipeData)
        let recipe = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(recipe.keys) == ["schema_version", "command", "env", "ready", "install", "env_from_source"])
        #expect(recipe["schema_version"] as? String == "1.0")
        #expect(recipe["command"] as? String == "npm run dev")
        #expect(recipe["env"] as? [String: String] == ["PORT": "{port}", "HOST": "127.0.0.1"])
        #expect((recipe["ready"] as? [String: String]) == ["http": "/"])
        #expect((recipe["install"] as? [String: String]) == ["command": "npm ci --no-audit --no-fund", "unless_exists": "node_modules"])
        #expect(recipe["env_from_source"] as? [String] == [".env"])
        #expect(String(data: data, encoding: .utf8)?.hasSuffix("}\n") == true)
    }

    @Test func yourEditsAreWhatsWritten() throws {
        var setup = PreviewSetup(Self.adonis, folderName: "site")
        setup.command.value = "npm run dev:local"
        setup.env.value = "PORT={port}  HOST=0.0.0.0 bad"
        setup.ready.value = "health"
        setup.install.value = ""
        let data = try #require(setup.recipeData)
        let recipe = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(recipe["command"] as? String == "npm run dev:local")
        #expect(recipe["env"] as? [String: String] == ["PORT": "{port}", "HOST": "0.0.0.0"])
        #expect((recipe["ready"] as? [String: String]) == ["http": "/health"])
        #expect(recipe["install"] == nil)
        setup.command.value = "  "
        #expect(setup.recipeData == nil, "no command, nothing to approve")
    }

    @Test func aValueTheRulesDidntFindIsBlankNotInvented() {
        let setup = PreviewSetup(ProjectSetupDetector.detect(packageJSON: #"{"scripts":{"dev":"node my-server.mjs"}}"#, files: []), folderName: "x")
        #expect(setup.env == .init(value: "", source: nil))
        #expect(setup.ready == .init(value: "", source: nil))
        #expect(setup.install == .init(value: "", source: nil))
    }

    @Test func itsWrittenIntoTheCheckoutAndNeverOverwritten() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data("{\"schema_version\":\"1.0\",\"command\":\"npm run dev\"}\n".utf8)
        try PreviewSetup.write(data, into: dir)
        let file = dir.appendingPathComponent(".darkmux/preview.json")
        #expect(try Data(contentsOf: file) == data)
        #expect(throws: PreviewSetup.WriteError.exists) { try PreviewSetup.write(Data("other".utf8), into: dir) }
        #expect(try Data(contentsOf: file) == data, "the first stays")
    }

    @Test func aSymlinkedDarkmuxFolderIsRefused() throws {
        let dir = try tempDir()
        let elsewhere = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(".darkmux"), withDestinationURL: elsewhere)
        #expect(throws: PreviewSetup.WriteError.symlink) { try PreviewSetup.write(Data("x".utf8), into: dir) }
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("preview.json").path))
    }

    @Test func theChosenFolderMustBeTheCheckout() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(PreviewSetup.sameFolder(dir, URL(fileURLWithPath: dir.path + "/")))
        #expect(!PreviewSetup.sameFolder(dir, dir.deletingLastPathComponent()))
    }

    @Test func theCheckoutIsReadForPackageJSONAndItsRootNames() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: dir.appendingPathComponent("package.json"))
        try Data().write(to: dir.appendingPathComponent("pnpm-lock.yaml"))
        let read = PreviewSetup.readCheckout(dir)
        #expect(read.packageJSON?.contains("vite") == true)
        #expect(read.files == ["package.json", "pnpm-lock.yaml"])
    }
}

@Suite(.serialized) @MainActor
struct PreviewSetupOfferTests {
    private func botWithCheckout(_ store: BotStore) -> Bot {
        let bot = store.add(name: "DE", instructions: "")
        store.addResource(.repo, "https://github.com/kstrat2001/darklyenergized", to: bot)
        bot.folderName = "darklyenergized"
        return bot
    }

    private func brain(checkout: URL?) -> BotBrain {
        let brain = BotBrain()
        brain.checkoutFolder = { _ in checkout }
        brain.checkoutReader = { _ in (#"{"scripts":{"dev":"node ace serve --hmr"}}"#, ["package-lock.json"]) }
        return brain
    }

    @Test func aCheckoutWithNoRecipeGetsOneCardOnce() throws {
        let store = TestStore.fresh()
        let bot = botWithCheckout(store)
        let brain = brain(checkout: URL(fileURLWithPath: "/tmp/darklyenergized"))
        brain.offerPreviewSetup(for: bot, store: store)
        brain.offerPreviewSetup(for: bot, store: store)
        let cards = (store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.kind == .actionCard }
        #expect(cards.count == 1)
        guard case let .setUpPreview(setup)? = cards.first?.action else { Issue.record("no setup card"); return }
        #expect(setup.framework == "AdonisJS")
        #expect(setup.folderName == "darklyenergized")
        #expect(cards.first?.actionState == .waiting, "nothing is written until Approve")
    }

    @Test func aCloneIsToldItNeedsYourCheckout() {
        let store = TestStore.fresh()
        let bot = botWithCheckout(store)
        let brain = brain(checkout: nil)
        brain.offerPreviewSetup(for: bot, store: store)
        brain.offerPreviewSetup(for: bot, store: store)
        let messages = store.conversation(for: .bot(bot.id)).messages ?? []
        #expect(!messages.contains { $0.kind == .actionCard })
        #expect(messages.filter { $0.content.contains("only from your own checkout") }.count == 1)
    }

    @Test func approvingKeepsTheExactFileForTheNextPR() async throws {
        let store = TestStore.fresh()
        let bot = botWithCheckout(store)
        let brain = brain(checkout: URL(fileURLWithPath: "/tmp/darklyenergized"))
        brain.offerPreviewSetup(for: bot, store: store)
        let card = try #require((store.conversation(for: .bot(bot.id)).messages ?? []).first { $0.kind == .actionCard })
        guard case let .setUpPreview(setup)? = card.action else { Issue.record("no card"); return }
        brain.resolve(card, approve: true, store: store)
        #expect(card.actionState == .approved)
        #expect(LocalBotState.shared[bot.id]?.prFiles?[PreviewSetup.path] == setup.recipeData)
    }

    @Test func cancelingKeepsNothing() throws {
        let store = TestStore.fresh()
        let bot = botWithCheckout(store)
        let brain = brain(checkout: URL(fileURLWithPath: "/tmp/darklyenergized"))
        brain.offerPreviewSetup(for: bot, store: store)
        let card = try #require((store.conversation(for: .bot(bot.id)).messages ?? []).first { $0.kind == .actionCard })
        brain.resolve(card, approve: false, store: store)
        #expect(LocalBotState.shared[bot.id]?.prFiles == nil)
    }
}

/// Approved files ride along in the PR's commit, exactly, but never over
/// the bot's own change to that path or one the base branch already has.
@Suite(.serialized) @MainActor
struct PRApprovedFileTests {
    private let changes = DarkmuxClient.Changes(
        base: "b0b0", baseBranch: "main", head: "h1h1", branch: "mux/de-1",
        files: [.init(path: "src/app.ts", mode: "100644", content: "Y2hhbmdlZAo=", deleted: nil)])

    private func stubTheRest() {
        GitHubStub.on("POST /repos/kstrat2001/de/git/blobs", 201, #"{"sha":"blob1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/de/git/blobs", 201, #"{"sha":"blob2"}"#)
        GitHubStub.on("GET /repos/kstrat2001/de/git/commits/b0b0", 200, #"{"sha":"b0b0","tree":{"sha":"tree0"}}"#)
        GitHubStub.on("POST /repos/kstrat2001/de/git/trees", 201, #"{"sha":"tree1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/de/git/commits", 201, #"{"sha":"commit1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/de/git/refs", 201, #"{"ref":"refs/heads/mux/de-1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/de/pulls", 201, #"{"number":5,"html_url":"https://github.com/kstrat2001/de/pull/5"}"#)
    }

    private func client() -> GitHubPR { GitHubPR(session: GitHubStub.session, token: "t", local: LocalBotState(fileURL: nil)) }

    @Test func theApprovedFileGoesInExactly() async throws {
        GitHubStub.reset()
        stubTheRest()
        let recipe = Data("{\"schema_version\":\"1.0\",\"command\":\"npm run dev\"}\n".utf8)
        let pr = try await client().open(changes, repo: "kstrat2001/de", title: "x", body: "y", bot: UUID(),
                                         extraFiles: [PreviewSetup.path: recipe])
        #expect(pr.added == [PreviewSetup.path])
        let blobs = GitHubStub.seen.filter { $0.method == "POST" && $0.path.hasSuffix("/git/blobs") }.compactMap { $0.body?["content"] as? String }
        #expect(blobs.contains(recipe.base64EncodedString()))
        let tree = GitHubStub.seen.first { $0.path.hasSuffix("/git/trees") }?.body?["tree"] as? [[String: Any]] ?? []
        #expect(tree.contains { $0["path"] as? String == PreviewSetup.path })
        let asked = GitHubStub.seen.first { $0.path.hasSuffix("/contents/.darkmux/preview.json") }
        #expect(asked?.query == "ref=b0b0", "checked against the base, not guessed")
    }

    @Test func oneTheBaseHasIsLeftOut() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kstrat2001/de/contents/.darkmux/preview.json", 200, #"{"name":"preview.json"}"#)
        stubTheRest()
        let pr = try await client().open(changes, repo: "kstrat2001/de", title: "x", body: "y", bot: UUID(),
                                         extraFiles: [PreviewSetup.path: Data("{}".utf8)])
        #expect(pr.added.isEmpty)
        #expect(pr.skipped[PreviewSetup.path] == .inBase)
        let tree = GitHubStub.seen.first { $0.path.hasSuffix("/git/trees") }?.body?["tree"] as? [[String: Any]] ?? []
        #expect(!tree.contains { $0["path"] as? String == PreviewSetup.path })
    }

    @Test func oneTheBotChangedIsLeftOut() async throws {
        GitHubStub.reset()
        stubTheRest()
        let pr = try await client().open(changes, repo: "kstrat2001/de", title: "x", body: "y", bot: UUID(),
                                         extraFiles: ["src/app.ts": Data("mine".utf8)])
        #expect(pr.skipped["src/app.ts"] == .inChanges)
        let blobs = GitHubStub.seen.filter { $0.path.hasSuffix("/git/blobs") }.compactMap { $0.body?["content"] as? String }
        #expect(!blobs.contains(Data("mine".utf8).base64EncodedString()))
    }
}
