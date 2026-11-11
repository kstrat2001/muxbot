import Foundation
import SwiftData

/// The current store: the live model types. V5 adds when a bot was archived
/// (`Bot.archivedAt`, optional), so V4 → V5 is lightweight.
enum SchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ChatConversation.self, ChatMessage.self, Bot.self,
         BotTask.self, BotResource.self, BotRun.self]
    }
}
