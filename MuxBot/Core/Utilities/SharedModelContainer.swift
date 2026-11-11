import Foundation
import SwiftData

/// The one SwiftData container. Uses the App Group container when that
/// entitlement is provisioned (for future widgets / intents), else
/// Application Support.
enum SharedModelContainer {
    static let appGroupIdentifier = "group.com.darklyenergized.darkmuxapp"

    static let schema = Schema(versionedSchema: SchemaV5.self)
    static let cloudContainer = "iCloud.com.darklyenergized.darkmuxapp"

    /// Whether this build syncs through iCloud: `MUXBOT_CLOUD_SYNC = YES` in
    /// the build's config (it also needs the iCloud entitlements, which need
    /// the developer account's iCloud container).
    static func cloudSyncEnabled(info: [String: Any]? = Bundle.main.infoDictionary) -> Bool {
        (info?["MuxBotCloudSync"] as? String)?.uppercased() == "YES"
    }

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

    static var storeURL: URL { storeDirectory.appendingPathComponent("MuxBot.store") }

    static func create() throws -> ModelContainer {
        try open(storeURL: storeURL, local: .shared, cloudSync: cloudSyncEnabled())
    }

    /// Opens (migrating if needed) the store. With sync on, bots, runs and
    /// threads go to the user's private iCloud database; machine-local state
    /// stays in `local`.
    static func open(storeURL: URL, local: LocalBotState, cloudSync: Bool) throws -> ModelContainer {
        MuxBotMigrationPlan.localState = local
        let config = ModelConfiguration(schema: schema, url: storeURL,
                                        cloudKitDatabase: cloudSync ? .private(cloudContainer) : .none)
        return try ModelContainer(for: schema, migrationPlan: MuxBotMigrationPlan.self, configurations: [config])
    }

    /// Moves a store that won't open aside (never deletes it), so the app can
    /// start fresh and the old files stay for recovery. Returns the new paths.
    @discardableResult
    static func moveAside(storeURL: URL, stamp: String) throws -> [URL] {
        let fm = FileManager.default
        var moved: [URL] = []
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            let to = URL(fileURLWithPath: from.path + ".moved-\(stamp)")
            try fm.moveItem(at: from, to: to)
            moved.append(to)
        }
        return moved
    }

    /// In-memory container for tests and previews. Never CloudKit: a
    /// configuration's default (`.automatic`) mirrors to the user's private
    /// database whenever the app has the iCloud entitlement, so a test that
    /// clears its store would delete the user's real bots everywhere.
    static func inMemory() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                                                            cloudKitDatabase: .none)])
    }
}
