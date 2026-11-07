import Foundation
import SwiftData

/// The store as the app wrote it before schemas were versioned (through
/// November 2026). Frozen: never edit; it is how migration recognizes old
/// stores. Machine-local fields (workspace, folder) and a few dead ones
/// lived on the synced models here.
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ChatConversation.self, ChatMessage.self, Bot.self, BotTask.self, BotResource.self, BotRun.self]
    }

    @Model
    final class Bot {
        var id: UUID = UUID()
        var name: String = ""
        var instructions: String = ""
        var modelName: String = ""
        var systemImage: String = "sparkles"
        @Attribute(.externalStorage) var avatarImageData: Data?
        var state: BotState = BotState.ready
        var createdAt: Date = Date()
        var workspaceName: String?
        var workspaceMachine: String?
        var folderBookmark: Data?
        var folderName: String?
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

        init(title: String) { self.title = title }
    }

    @Model
    final class BotRun {
        var id: UUID = UUID()
        var task: String = ""
        var brief: String?
        var crew: CrewRole = CrewRole.coder
        var phase: RunPhase = RunPhase.proposed
        var summary: String = ""
        var previewURL: String?
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
        var isSimulated: Bool = false
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

        init(title: String, roleId: UUID?) {
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
