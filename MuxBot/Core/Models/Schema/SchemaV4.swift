import Foundation
import SwiftData

/// The current store: the live model types. V4 adds the use case a bot was
/// started from (`Bot.useCaseId`) and the skills copied from its playbook
/// (`Bot.skillsJSON`), both defaulted, so V3 → V4 is lightweight.
enum SchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ChatConversation.self, ChatMessage.self, Bot.self,
         BotTask.self, BotResource.self, BotRun.self]
    }
}
