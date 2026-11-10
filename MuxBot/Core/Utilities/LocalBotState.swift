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
        /// The commit this Mac last wrote to each of the bot's GitHub
        /// branches, by branch name: Open PR moves a branch only from there,
        /// never past a commit someone else pushed (`GitHubPR`).
        var pushedHeads: [String: String]?
        /// Files you approved for the bot's pull requests (path → the exact
        /// bytes), added to each PR's commit until the base branch has them
        /// (`PreviewSetup`).
        var prFiles: [String: Data]?
        /// A project started on GitHub: its start commit there, its default
        /// branch and the branch the bot's work goes to (`GitHubPR.Start`).
        var githubStart: GitHubPR.Start?
        /// The bot's runs started from this device (by id): this Mac's
        /// darkmux has them. Others (synced from another Mac) are never
        /// followed, stopped or undone from here.
        var localRuns: [String]?
        /// Each run's darkmux work ids, oldest first (the run, then each
        /// Tweak): Undo reverts them all, newest first.
        var runWorkIds: [String: [String]]?

        var isEmpty: Bool {
            workspaceName == nil && workspaceMachine == nil && folderBookmark == nil && folderName == nil && previewViewport == nil
                && (dismissedRuns ?? []).isEmpty && (pushedHeads ?? [:]).isEmpty && (prFiles ?? [:]).isEmpty && githubStart == nil
                && (localRuns ?? []).isEmpty && (runWorkIds ?? [:]).isEmpty
        }
    }

    @ObservationIgnored private let fileURL: URL?
    /// By bot id (`uuidString`): a plain JSON object on disk. Behind a lock,
    /// since the schema migration writes off the main actor; observers are
    /// told around a change (`withMutation`), never while it's held.
    @ObservationIgnored private let entries: Mutex<[String: Entry]>

    /// `nil` keeps it in memory only (tests).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        var saved: [String: Entry] = [:]
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            saved = decoded
        }
        entries = Mutex(saved)
    }

    /// What views observe: any entry changing.
    private var allEntries: [String: Entry] { entries.withLock { $0 } }

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
        get {
            access(keyPath: \.allEntries)
            return entries.withLock { $0[id.uuidString] }
        }
        set { update(id) { $0 = newValue ?? Entry() } }
    }

    /// Changes one bot's entry in place: read, change and save under one
    /// lock, so concurrent updates never lose one. `change` must not touch
    /// this state itself.
    func update(_ id: UUID, _ change: (inout Entry) -> Void) {
        withMutation(keyPath: \.allEntries) {
            entries.withLock { all in
                var entry = all[id.uuidString] ?? Entry()
                change(&entry)
                all[id.uuidString] = entry.isEmpty ? nil : entry
                save(all)
            }
        }
    }

    private func save(_ all: [String: Entry]) {
        guard let fileURL, let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
