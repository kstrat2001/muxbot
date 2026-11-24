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
        #expect(recipe["env"] as? [String: String] == ["PORT": "{port}", "HOST": "0.0.0.0"])
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
        // Install comes from package.json with no lockfile (sweep 6b #15).
        #expect(setup.install == .init(value: "npm install --no-audit --no-fund", source: "package.json, no lockfile"))
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

    @Test func approvingSavesTheExactFileWithTheProjectsChanges() async throws {
        let store = TestStore.fresh()
        let bot = botWithCheckout(store)
        bot.workspaceName = "de-1"
        let brain = brain(checkout: URL(fileURLWithPath: "/tmp/darklyenergized"))
        let saved = DataBox()
        brain.runs.fileAdder = { _, path, data in saved.set(path, data); return .init(path: path, workId: "w-1", commit: "abc1234", branch: "mux/de-1") }
        brain.offerPreviewSetup(for: bot, store: store)
        let card = try #require((store.conversation(for: .bot(bot.id)).messages ?? []).first { $0.kind == .actionCard })
        guard case let .setUpPreview(setup)? = card.action else { Issue.record("no card"); return }
        brain.resolve(card, approve: true, store: store)
        #expect(card.actionState == .approved)
        for _ in 0..<100 where saved.path == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(saved.path == PreviewSetup.path)
        #expect(saved.data == setup.recipeData, "exactly the approved bytes")
    }

    @Test func cancelingKeepsNothing() async throws {
        let store = TestStore.fresh()
        let bot = botWithCheckout(store)
        bot.workspaceName = "de-1"
        let brain = brain(checkout: URL(fileURLWithPath: "/tmp/darklyenergized"))
        let saved = DataBox()
        brain.runs.fileAdder = { _, path, data in saved.set(path, data); return .init(path: path, workId: "w-1", commit: nil, branch: nil) }
        brain.offerPreviewSetup(for: bot, store: store)
        let card = try #require((store.conversation(for: .bot(bot.id)).messages ?? []).first { $0.kind == .actionCard })
        brain.resolve(card, approve: false, store: store)
        try await Task.sleep(for: .milliseconds(50))
        #expect(saved.path == nil)
    }
}

/// The approved bytes a test saw.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _path: String?
    private var _data: Data?
    var path: String? { lock.withLock { _path } }
    var data: Data? { lock.withLock { _data } }
    func set(_ path: String, _ data: Data) { lock.withLock { _path = path; _data = data } }
}
