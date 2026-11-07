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
    ])

    static var storeDirectory: URL {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MuxBot")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func create() throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, url: storeDirectory.appendingPathComponent("MuxBot.store"))
        return try ModelContainer(for: schema, configurations: [config])
    }
}
