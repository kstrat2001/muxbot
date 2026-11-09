import Foundation
import Observation
import Synchronization

/// What a bot has on this machine only: its darkmux workspace and the
/// project folder you picked. Kept in a small file in the app's own
/// container, keyed by bot id, never in the synced store: another Mac or
/// the phone has its own (or none).
@Observable
final class LocalBotState: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var workspaceName: String?
        var workspaceMachine: String?
        var folderBookmark: Data?
        var folderName: String?
        /// The preview's device size (`PreviewViewport` raw value) you last
        /// picked for this bot.
        var previewViewport: String?
        /// Runs whose "needs you" you hid here (the banner's ×), by id.
        var dismissedRuns: [String]?
        /// This bot's model mode (`ModelMode.stored`); nil follows Settings.
        var modelMode: String?

        var isEmpty: Bool {
            workspaceName == nil && workspaceMachine == nil && folderBookmark == nil && folderName == nil && previewViewport == nil
                && (dismissedRuns ?? []).isEmpty && modelMode == nil
        }
    }

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let lock = Mutex(())
    /// By bot id (`uuidString`): a plain JSON object on disk.
    private var entries: [String: Entry] = [:]

    /// `nil` keeps it in memory only (tests).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    /// The app's own: Application Support/MuxBot/local-bots.json, or in
    /// memory under tests so they never touch the real file.
    static let shared: LocalBotState = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return LocalBotState(fileURL: nil) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("MuxBot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LocalBotState(fileURL: dir.appendingPathComponent("local-bots.json"))
    }()

    subscript(id: UUID) -> Entry? {
        get { lock.withLock { _ in entries[id.uuidString] } }
        set {
            lock.withLock { _ in
                if let newValue, !newValue.isEmpty { entries[id.uuidString] = newValue } else { entries[id.uuidString] = nil }
                save()
            }
        }
    }

    /// Changes one bot's entry in place.
    func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        var entry = self[id] ?? Entry()
        change(&entry)
        self[id] = entry
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
