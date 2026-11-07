import Foundation
import SwiftData
import Testing
@testable import MuxBot

@Suite(.serialized) @MainActor
struct SchemaMigrationTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muxbot-mig-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a store as the app wrote it before versioning (SchemaV1).
    private func writeV1Store(at url: URL) throws -> (botId: UUID, otherId: UUID) {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let context = ModelContext(container)
        let hcr = SchemaV1.Bot(name: "humancodereader", instructions: "Site")
        hcr.workspaceName = "hcr-humancodereader"
        hcr.workspaceMachine = "MacBook Pro"
        hcr.folderName = "hcr"
        hcr.folderBookmark = Data([7, 7])
        hcr.modelName = "qwen"
        context.insert(hcr)
        let seeded = SchemaV1.BotResource(kind: .previewURL, value: "http://some-mac.some-tailnet.ts.net:8445/")
        context.insert(seeded); seeded.bot = hcr
        let mine = SchemaV1.BotResource(kind: .previewURL, value: "http://localhost:5173/")
        context.insert(mine); mine.bot = hcr
        let mineOnTailnet = SchemaV1.BotResource(kind: .previewURL, value: "http://some-mac.some-tailnet.ts.net:3000/")
        context.insert(mineOnTailnet); mineOnTailnet.bot = hcr
        let repo = SchemaV1.BotResource(kind: .repo, value: "https://github.com/kstrat2001/hcr")
        context.insert(repo); repo.bot = hcr
        let other = SchemaV1.Bot(name: "Personal brand", instructions: "Posts")
        let otherLink = SchemaV1.BotResource(kind: .previewURL, value: "http://another.ts.net:8445/")
        context.insert(other); context.insert(otherLink); otherLink.bot = other
        let run = SchemaV1.BotRun(task: "Fix #8", crew: .coder)
        run.isSimulated = true
        run.previewURL = "http://x/"
        context.insert(run); run.bot = hcr
        let thread = SchemaV1.ChatConversation(title: "humancodereader", roleId: hcr.id)
        context.insert(thread)
        let message = SchemaV1.ChatMessage(role: .user, content: "hello")
        context.insert(message); message.conversation = thread
        try context.save()
        return (hcr.id, other.id)
    }

    @Test func anUnversionedStoreMigratesAndKeepsEverythingThatMatters() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("MuxBot.store")
        let (botId, otherId) = try writeV1Store(at: url)
        let local = LocalBotState(fileURL: dir.appendingPathComponent("local.json"))

        let container = try SharedModelContainer.open(storeURL: url, local: local, cloudSync: false)
        let context = ModelContext(container)
        let bots = try context.fetch(FetchDescriptor<Bot>())
        let hcr = try #require(bots.first { $0.id == botId })
        #expect(bots.count == 2)
        // Machine-local state moved off the synced model, by bot id.
        #expect(local[botId] == .init(workspaceName: "hcr-humancodereader", workspaceMachine: "MacBook Pro",
                                      folderBookmark: Data([7, 7]), folderName: "hcr"))
        // The seeded tailnet test link is gone; the user's own links stay.
        #expect(Set(hcr.sortedResources.map(\.value))
                == ["http://localhost:5173/", "http://some-mac.some-tailnet.ts.net:3000/", "https://github.com/kstrat2001/hcr"])
        #expect(bots.first { $0.id == otherId }?.sortedResources.count == 1, "only humancodereader's seed is removed")
        // Runs and threads come through.
        #expect(hcr.runs?.first?.task == "Fix #8")
        #expect(try context.fetch(FetchDescriptor<ChatMessage>()).map(\.content) == ["hello"])
        // Reopening is a no-op.
        _ = try SharedModelContainer.open(storeURL: url, local: local, cloudSync: false)
    }

    @Test func aV2StoreOpensAsV3AndBotsKeepASuggestedLook() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("MuxBot.store")
        let schema = Schema(versionedSchema: SchemaV2.self)
        let v2 = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let writer = ModelContext(v2)
        let old = SchemaV2.Bot(name: "darkmux", instructions: "CLI")
        writer.insert(old)
        try writer.save()
        let id = old.id

        let container = try SharedModelContainer.open(storeURL: url, local: LocalBotState(fileURL: dir.appendingPathComponent("local.json")), cloudSync: false)
        let bot = try #require(try ModelContext(container).fetch(FetchDescriptor<Bot>()).first { $0.id == id })
        #expect(bot.avatarAnimal.isEmpty && bot.bodyColorHex.isEmpty && bot.eyeColorHex.isEmpty)
        #expect(bot.look == BotLook.suggested(for: "darkmux"))
        #expect(bot.look.animal == .raccoon)
    }

    @Test func renamingKeepsTheLookAndPickedLooksStick() {
        let bot = Bot(name: "humancodereader", instructions: "")
        let suggested = bot.look
        bot.look = suggested
        bot.name = "hcr"
        #expect(bot.look == suggested)
        bot.look = BotLook(animal: .dog, bodyHex: "3d9a4a", eyeHex: "ffc23d")
        #expect(bot.look.animal == .dog && bot.look.eyeHex == "ffc23d")
    }

    @Test func localStatePersistsPerMachineNotInTheSyncedStore() throws {
        let file = tempDir().appendingPathComponent("local.json")
        let id = UUID()
        let a = LocalBotState(fileURL: file)
        a[id] = .init(workspaceName: "w", workspaceMachine: "Mac", folderBookmark: nil, folderName: nil)
        let b = LocalBotState(fileURL: file)
        #expect(b[id]?.workspaceName == "w")
        // A readable object keyed by bot id.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect((json?[id.uuidString] as? [String: Any])?["workspaceName"] as? String == "w")
        a[id] = nil
        #expect(LocalBotState(fileURL: file)[id] == nil)
    }

    @Test func aBrokenStoreIsMovedAsideNeverDeleted() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("MuxBot.store")
        for suffix in ["", "-wal", "-shm"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: url.path + suffix))
        }
        let moved = try SharedModelContainer.moveAside(storeURL: url, stamp: "20261107-1200")
        #expect(moved.count == 3)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: url.path + ".moved-20261107-1200"))
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal.moved-20261107-1200"))
    }

    @Test func cloudSyncIsOffUnlessTheBuildTurnsItOn() {
        #expect(!SharedModelContainer.cloudSyncEnabled(info: [:]))
        #expect(!SharedModelContainer.cloudSyncEnabled(info: ["MuxBotCloudSync": "NO"]))
        #expect(!SharedModelContainer.cloudSyncEnabled(info: ["MuxBotCloudSync": "$(MUXBOT_CLOUD_SYNC)"]))
        #expect(SharedModelContainer.cloudSyncEnabled(info: ["MuxBotCloudSync": "YES"]))
    }

    @Test func theSyncedModelsAreCloudKitSafe() {
        // No unique constraints, every attribute optional or defaulted, every
        // relationship optional: what CloudKit sync requires.
        for entity in Schema(versionedSchema: SchemaV3.self).entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name)")
            for rel in entity.relationships { #expect(rel.isOptional, "\(entity.name).\(rel.name)") }
            for attr in entity.attributes where !attr.isOptional {
                #expect(attr.defaultValue != nil, "\(entity.name).\(attr.name) needs a default")
            }
        }
        let bot = Schema(versionedSchema: SchemaV3.self).entities.first { $0.name == "Bot" }
        let names = Set(bot?.attributes.map(\.name) ?? [])
        #expect(names.isDisjoint(with: ["workspaceName", "workspaceMachine", "folderBookmark", "folderName", "modelName"]))
    }
}

@Suite(.serialized) @MainActor
struct FirstLaunchTests {
    @Test func aNewInstallStartsEmptyAndTheExampleIsOnRequest() {
        let store = TestStore.fresh()
        #expect(store.allBots().isEmpty)
        store.addExample()
        store.addExample()
        #expect(store.allBots().map(\.name) == ["My website"], "one example, never duplicated")
    }
}

@MainActor
struct TestHostIsolationTests {
    /// The app is the test host: under tests it must use an in-memory store,
    /// never the user's real one (an earlier run migrated the real store).
    @Test func theTestHostNeverOpensTheRealStore() throws {
        #expect(StoreLoader.isTestHost)
        let loader = StoreLoader()
        let container = try #require(loader.container)
        #expect(container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
    }
}
