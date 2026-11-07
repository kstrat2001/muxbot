import Foundation
import SwiftData

/// The current store: the live model types. V3 adds the bot's character
/// (`Bot.avatarAnimal`, `bodyColorHex`, `eyeColorHex`, all defaulted), so
/// V2 → V3 is lightweight.
enum SchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ChatConversation.self, ChatMessage.self, Bot.self,
         BotTask.self, BotResource.self, BotRun.self]
    }
}
