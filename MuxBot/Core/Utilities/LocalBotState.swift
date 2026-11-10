import Foundation
import Observation
import OSLog
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
        /// The GitHub branch this Mac pushes the bot's work to when it isn't
        /// darkmux's branch name: someone else pushed to that one, so the
        /// work moved to the next free name (`RunCoordinator.pushMovingOn`).
        var pushHead: String?
        /// Put it on GitHub made the repo but hasn't pushed the project's
        /// work into it yet: Put resumes into that repo, and backups wait.
        var putPending: Bool?
        /// Put it on GitHub made this repo but couldn't fill it: Put again
        /// fills it, never a second one.
        var putMadeRepo: String?
        /// Runs finished before this are already on GitHub (Put it on GitHub
        /// pushed them to the default branch): Open PR doesn't offer them.
        var shippedThrough: Date?
        /// Each Tweak in flight's result before it, by run id: a Tweak that
        /// doesn't make it (after a relaunch too) goes back to it.
        var tweakBases: [String: RunCoordinator.TweakBase]?
        /// The pairing each run was submitted under (`FleetConnection.pairingId`).
        var runPairings: [String: String]?

        var isEmpty: Bool {
            workspaceName == nil && workspaceMachine == nil && folderBookmark == nil && folderName == nil && previewViewport == nil
                && (dismissedRuns ?? []).isEmpty && (pushedHeads ?? [:]).isEmpty && (prFiles ?? [:]).isEmpty && githubStart == nil
                && (localRuns ?? []).isEmpty && (runWorkIds ?? [:]).isEmpty && pushHead == nil && putPending == nil && putMadeRepo == nil && shippedThrough == nil && (tweakBases ?? [:]).isEmpty && (runPairings ?? [:]).isEmpty
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
        entries = Mutex(fileURL.map(Self.read) ?? [:])
    }

    private static let log = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "local-state")

    /// One bot's entry, or nothing when it can't be read: a bad entry costs
    /// only itself, never the others.
    private struct Lossy: Decodable {
        var entry: Entry?
        init(from decoder: any Decoder) throws { entry = try? Entry(from: decoder) }
    }

    /// The file's entries. One that can't be read is left out (and said in
    /// the log). A file that isn't this state at all is moved aside next to
    /// itself, never deleted, so the next save doesn't write over it.
    static func read(_ fileURL: URL) -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([String: Lossy].self, from: data)
            let bad = decoded.filter { $0.value.entry == nil }.keys.sorted()
            if !bad.isEmpty { log.error("local-bots.json: \(bad.count) entries couldn't be read and were left out: \(bad.joined(separator: ", "), privacy: .public)") }
            return decoded.compactMapValues(\.entry)
        } catch {
            let aside = unreadableURL(for: fileURL, at: Date())
            do {
                try FileManager.default.moveItem(at: fileURL, to: aside)
                log.error("local-bots.json couldn't be read (\(error.localizedDescription, privacy: .public)); kept as \(aside.lastPathComponent, privacy: .public)")
            } catch let moveError {
                log.error("local-bots.json couldn't be read (\(error.localizedDescription, privacy: .public)) or moved aside (\(moveError.localizedDescription, privacy: .public))")
            }
            return [:]
        }
    }

    /// `local-bots.json.unreadable-<timestamp>`, beside the file.
    static func unreadableURL(for fileURL: URL, at date: Date) -> URL {
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
            .replacingOccurrences(of: ":", with: "")
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(fileURL.lastPathComponent).unreadable-\(stamp)")
    }

    /// What views observe: any entry changing.
    private var allEntries: [String: Entry] { entries.withLock { $0 } }

    /// The app's own: Application Support/MuxBot/local-bots.json, or in
    /// memory under tests so they never touch the real file.
    static let shared: LocalBotState = {
        if TestIsolation.isTesting { return LocalBotState(fileURL: nil) }
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
        guard let fileURL else { return }
        do {
            try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("local-bots.json couldn't be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
