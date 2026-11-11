import Foundation
import SwiftData

/// The store as batch 4 wrote it (November 2026). Frozen: never edit; it is
/// how migration recognizes V2 stores. CloudKit-ready (no unique
/// constraints, every attribute defaulted or optional, optional
/// relationships). Machine-local state is in `LocalBotState`, not here.
/// Dropped from V1: Bot.modelName, the workspace and folder fields (moved to
/// `LocalBotState`), BotRun.previewURL and BotRun.isSimulated.
enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ChatConversation.self, ChatMessage.self, Bot.self, BotTask.self, BotResource.self, BotRun.self]
    }

    @Model
    final class Bot {
        var id: UUID = UUID()
        var name: String = ""
        var instructions: String = ""
        var systemImage: String = "sparkles"
        @Attribute(.externalStorage) var avatarImageData: Data?
        var state: BotState = BotState.ready
        var createdAt: Date = Date()
        @Relationship(deleteRule: .cascade, inverse: \BotTask.bot)
        var tasks: [BotTask]? = []
        @Relationship(deleteRule: .cascade, inverse: \BotResource.bot)
        var resources: [BotResource]? = []
        @Relationship(deleteRule: .cascade, inverse: \BotRun.bot)
        var runs: [BotRun]? = []

        init(name: String, instructions: String) {
            self.name = name
            self.instructions = instructions
        }
    }

    @Model
    final class BotResource {
        var id: UUID = UUID()
        var kind: ResourceKind = ResourceKind.note
        var value: String = ""
        var createdAt: Date = Date()
        var bot: Bot?

        init(kind: ResourceKind, value: String) {
            self.kind = kind
            self.value = value
        }
    }

    @Model
    final class BotTask {
        var id: UUID = UUID()
        var title: String = ""
        var why: String = ""
        var crew: CrewRole?
        var createdAt: Date = Date()
        var bot: Bot?

        init(title: String, why: String) {
            self.title = title
            self.why = why
        }
    }

    @Model
    final class BotRun {
        var id: UUID = UUID()
        var task: String = ""
        var brief: String?
        var crew: CrewRole = CrewRole.coder
        var phase: RunPhase = RunPhase.proposed
        var summary: String = ""
        var tweaks: Int = 0
        var startedAt: Date?
        var finishedAt: Date?
        var darkmuxWorkId: String?
        var notes: String?
        var changedFiles: [String] = []
        var diff: String?
        var details: String?
        var keptBranch: String?
        var keptCommit: String?
        var createdAt: Date = Date()
        var bot: Bot?

        init(task: String, crew: CrewRole) {
            self.task = task
            self.crew = crew
        }
    }

    @Model
    final class ChatConversation {
        var id: UUID = UUID()
        var title: String = ""
        var roleId: UUID?
        var createdAt: Date = Date()
        var updatedAt: Date = Date()
        var lastReadAt: Date?
        @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
        var messages: [ChatMessage]? = []

        init(title: String = "", roleId: UUID? = nil) {
            self.title = title
            self.roleId = roleId
        }
    }

    @Model
    final class ChatMessage {
        var id: UUID = UUID()
        var role: ChatRole = ChatRole.user
        var content: String = ""
        var timestamp: Date = Date()
        var kind: MessageKind = MessageKind.text
        var runId: UUID?
        var intentRaw: String?
        var elementJSON: String?
        var actionJSON: String?
        var actionStateRaw: String?
        var conversation: ChatConversation?

        init(role: ChatRole, content: String) {
            self.role = role
            self.content = content
        }
    }
}

/// How older stores become the current one.
enum MuxBotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, SchemaV5.self] }
    static var stages: [MigrationStage] { [v1ToV2, v2ToV3, v3ToV4, v4ToV5] }

    /// V5 only adds an optional field (when a bot was archived).
    static let v4ToV5 = MigrationStage.lightweight(fromVersion: SchemaV4.self, toVersion: SchemaV5.self)

    /// V4 only adds defaulted fields (the bot's use case and skills).
    static let v3ToV4 = MigrationStage.lightweight(fromVersion: SchemaV3.self, toVersion: SchemaV4.self)

    /// V3 only adds defaulted fields (the bot's character).
    static let v2ToV3 = MigrationStage.lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self)

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
