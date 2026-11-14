import Foundation
import SwiftData
import Testing
@testable import MuxBot

/// A model no shipped schema has: a store saved with it stands in for one a
/// newer Mux Bot migrated.
@Model final class FutureOnlyThing {
    var name: String = ""
    init() {}
}

@Suite(.serialized) @MainActor
struct StoreRecoveryTests {
    private let dirs = MigrationTempDirs()

    @Test func aStoreThisBuildWroteIsNotFromANewerApp() throws {
        let url = dirs.make().appendingPathComponent("MuxBot.store")
        _ = try SharedModelContainer.open(storeURL: url, local: LocalBotState(fileURL: nil), cloudSync: false)
        #expect(!SharedModelContainer.isFromNewerApp(storeURL: url))
    }

    @Test func aStoreFromAnUnknownSchemaIsFromANewerApp() throws {
        let url = dirs.make().appendingPathComponent("MuxBot.store")
        let schema = Schema(SchemaV5.models + [FutureOnlyThing.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let context = ModelContext(container)
        context.insert(FutureOnlyThing())
        try context.save()
        #expect(SharedModelContainer.isFromNewerApp(storeURL: url))
    }

    @Test func aMissingOrBrokenStoreIsNotFromANewerApp() throws {
        let url = dirs.make().appendingPathComponent("MuxBot.store")
        #expect(!SharedModelContainer.isFromNewerApp(storeURL: url))
        try Data("not a store".utf8).write(to: url)
        #expect(!SharedModelContainer.isFromNewerApp(storeURL: url))
    }

    #if os(macOS)
    @Test func aSecondCopyHandsOffOnlyToAnotherProcess() {
        #expect(SingleInstance.other(among: [42], me: 42) == nil)
        #expect(SingleInstance.other(among: [42, 7], me: 42) == 7)
        #expect(SingleInstance.other(among: [], me: 42) == nil)
    }
    #endif
}
