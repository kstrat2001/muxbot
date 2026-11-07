import Foundation
import SwiftData

/// The one SwiftData container. Uses the App Group container when that
/// entitlement is provisioned (for future widgets / intents), else
/// Application Support.
enum SharedModelContainer {
    static let appGroupIdentifier = "group.com.darklyenergized.darkmuxapp"

    static let schema = Schema([
        ChatConversation.self,
        ChatMessage.self,
        Bot.self,
        BotTask.self,
        BotResource.self,
    ])

    /// The App Group directory if the sandbox lets us write there, else
    /// Application Support. On macOS `containerURL` returns a path even
    /// without the entitlement, so writability is checked, not presence.
    static var storeDirectory: URL {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier),
           let dir = writableDirectory(group.appendingPathComponent("MuxBot")) {
            return dir
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("MuxBot")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writableDirectory(_ dir: URL) -> URL? {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              fm.isWritableFile(atPath: dir.path) else { return nil }
        return dir
    }

    static func create() throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, url: storeDirectory.appendingPathComponent("MuxBot.store"))
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// In-memory container for tests and previews.
    static func inMemory() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
}
