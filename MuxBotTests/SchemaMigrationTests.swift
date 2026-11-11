import Foundation
import SwiftData
import Testing
@testable import MuxBot

/// Temp folders for on-disk stores, removed when the test ends (and
/// leftovers from crashed runs swept), so the app's tmp doesn't fill up.
final class MigrationTempDirs: Sendable {
    static let prefix = "muxbot-mig-"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(MigrationTempDirs.prefix)\(UUID().uuidString)")

    init() {
        Self.sweep(olderThan: 3600)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func make() -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Removes `muxbot-mig-*` folders not touched for `age` seconds.
    static func sweep(olderThan age: TimeInterval, in tmp: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            let url = tmp.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantFuture
            if Date().timeIntervalSince(modified) > age { try? fm.removeItem(at: url) }
        }
    }
}

struct MigrationTempDirTests {
    @Test func aTestsFoldersGoWhenItEnds() {
        var dirs: MigrationTempDirs? = MigrationTempDirs()
        let made = dirs!.make()
        #expect(FileManager.default.fileExists(atPath: made.path))
        let root = dirs!.root
        dirs = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func staleLeftoversAreSweptFreshOnesKept() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let old = tmp.appendingPathComponent("\(MigrationTempDirs.prefix)old"), fresh = tmp.appendingPathComponent("\(MigrationTempDirs.prefix)fresh")
        let other = tmp.appendingPathComponent("not-ours")
        for d in [old, fresh, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: other.path)
        MigrationTempDirs.sweep(olderThan: 3600, in: tmp)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: other.path), "only ours")
    }
}

@Suite(.serialized) @MainActor
struct SchemaMigrationTests {
    private let dirs = MigrationTempDirs()
    private func tempDir() -> URL { dirs.make() }

    /// Writes a store as the app wrote it before versioning (SchemaV1).
    private func writeV1Store(at url: URL) throws -> (botId: UUID, otherId: UUID) {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
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
        let v2 = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
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

    @Test func aV3StoreOpensAsV4AndBotsKeepTheirLookWithNoUseCase() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("MuxBot.store")
        let schema = Schema(versionedSchema: SchemaV3.self)
        let v3 = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let writer = ModelContext(v3)
        let old = SchemaV3.Bot(name: "hcr", instructions: "Site")
        old.avatarAnimal = "owl"
        old.bodyColorHex = "0e9f8e"
        writer.insert(old)
        let resource = SchemaV3.BotResource(kind: .repo, value: "https://github.com/kstrat2001/hcr")
        resource.bot = old
        writer.insert(resource)
        try writer.save()
        let id = old.id

        let container = try SharedModelContainer.open(storeURL: url, local: LocalBotState(fileURL: dir.appendingPathComponent("local.json")), cloudSync: false)
        let bot = try #require(try ModelContext(container).fetch(FetchDescriptor<Bot>()).first { $0.id == id })
        #expect(bot.avatarAnimal == "owl" && bot.bodyColorHex == "0e9f8e")
        #expect(bot.useCaseId.isEmpty, "a bot from before use cases has none")
        #expect(bot.skills.isEmpty)
        #expect(bot.resources?.first?.value == "https://github.com/kstrat2001/hcr")
    }

    @Test func aV4StoreOpensAsV5AndNoBotIsArchived() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("MuxBot.store")
        let schema = Schema(versionedSchema: SchemaV4.self)
        let v4 = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let writer = ModelContext(v4)
        let old = SchemaV4.Bot(name: "site", instructions: "Site")
        old.useCaseId = "website"
        writer.insert(old)
        try writer.save()
        let id = old.id

        let container = try SharedModelContainer.open(storeURL: url, local: LocalBotState(fileURL: dir.appendingPathComponent("local.json")), cloudSync: false)
        let bot = try #require(try ModelContext(container).fetch(FetchDescriptor<Bot>()).first { $0.id == id })
        #expect(bot.useCaseId == "website")
        #expect(bot.archivedAt == nil && !bot.isArchived)
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

    /// Tests run inside the app, which has the iCloud entitlement in a sync
    /// build: no test store may ever mirror to CloudKit (it did, and test
    /// fixtures replaced a user's bots).
    @Test func testStoresNeverTouchICloud() throws {
        let memory = try SharedModelContainer.inMemory()
        #expect(memory.configurations.allSatisfy { $0.cloudKitContainerIdentifier == nil })
        #expect(TestStore.container.configurations.allSatisfy { $0.cloudKitContainerIdentifier == nil })
        let url = dirs.make().appendingPathComponent("MuxBot.store")
        let opened = try SharedModelContainer.open(storeURL: url, local: LocalBotState(fileURL: nil), cloudSync: false)
        #expect(opened.configurations.allSatisfy { $0.cloudKitContainerIdentifier == nil })
        // Every store a test makes says so explicitly.
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for file in try FileManager.default.contentsOfDirectory(at: tests, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") where line.contains("ModelConfiguration(") && !line.contains("cloudKitDatabase: .none") && !line.contains("contains(\"ModelConfiguration(\")") {
                Issue.record("\(file.lastPathComponent): a ModelConfiguration without cloudKitDatabase: .none: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
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
        for entity in Schema(versionedSchema: SchemaV5.self).entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name)")
            for rel in entity.relationships { #expect(rel.isOptional, "\(entity.name).\(rel.name)") }
            for attr in entity.attributes where !attr.isOptional {
                #expect(attr.defaultValue != nil, "\(entity.name).\(attr.name) needs a default")
            }
        }
        let bot = Schema(versionedSchema: SchemaV5.self).entities.first { $0.name == "Bot" }
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
