import Foundation
import SwiftData

/// The current store: the live model types. Ready for CloudKit sync (no
/// unique constraints, every attribute defaulted or optional, optional
/// relationships). Machine-local state is in `LocalBotState`, not here.
/// Dropped from V1: Bot.modelName, the workspace and folder fields (moved to
/// `LocalBotState`), BotRun.previewURL and BotRun.isSimulated.
enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ChatConversation.self, ChatMessage.self, Bot.self, BotTask.self, BotResource.self, BotRun.self]
    }
}

/// How older stores become the current one.
enum MuxBotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    static var stages: [MigrationStage] { [v1ToV2] }

    /// Where V1's machine-local fields go during the migration.
    nonisolated(unsafe) static var localState: LocalBotState = .shared

    static let v1ToV2 = MigrationStage.custom(
        fromVersion: SchemaV1.self, toVersion: SchemaV2.self,
        willMigrate: { context in
            // Workspace and folder are this machine's: move them out by bot id
            // before the synced model drops them.
            for bot in try context.fetch(FetchDescriptor<SchemaV1.Bot>()) {
                let entry = LocalBotState.Entry(workspaceName: bot.workspaceName, workspaceMachine: bot.workspaceMachine,
                                                folderBookmark: bot.folderBookmark, folderName: bot.folderName)
                if !entry.isEmpty { localState[bot.id] = entry }
            }
            // Earlier builds seeded humancodereader with a temporary tailnet test
            // server link (port 8445, now retired). Only that exact seed goes;
            // links the user added stay.
            for resource in try context.fetch(FetchDescriptor<SchemaV1.BotResource>())
            where resource.kind == .previewURL && resource.bot?.name == "humancodereader" && isSeededTestLink(resource.value) {
                context.delete(resource)
            }
            try context.save()
        },
        didMigrate: nil)

    static func isSeededTestLink(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "http", url.port == 8445,
              let host = url.host, host.hasSuffix(".ts.net") else { return false }
        return url.path.isEmpty || url.path == "/"
    }
}
