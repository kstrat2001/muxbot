import Foundation

/// Why a dispatch card can't start yet; the card offers the fix.
enum RunBlocker: Equatable, Sendable {
    /// The app isn't paired with darkmux on this Mac.
    case unpaired
    /// This crew role has no darkmux role yet.
    case noRole(String)
    /// The bot has no repo or folder to work in.
    case noCode
    /// The bot has code ("owner/repo" or a folder name) but no workspace on
    /// this Mac yet: the card offers to set one up.
    case needsWorkCopy(String)
    /// Runs start from the Mac app until phone pairing exists.
    case notOnThisDevice
    /// Another run's changes in the work copy wait for Keep or Discard; a
    /// new run never mixes with them.
    case pendingChanges(UUID)

    /// Runs start only from the Mac app until phone pairing exists.
    #if os(iOS)
    static let deviceRuns = false
    #else
    static let deviceRuns = true
    #endif

    @MainActor
    static func check(paired: Bool, crew: CrewRole, bot: Bot, deviceRuns: Bool = deviceRuns, excluding run: UUID? = nil) -> RunBlocker? {
        guard deviceRuns else { return .notOnThisDevice }
        guard paired else { return .unpaired }
        guard crew.darkmuxRole != nil else { return .noRole(crew.name) }
        if bot.workspaceName != nil {
            let waiting = (bot.runs ?? []).filter { $0.id != run && $0.phase == .result && !$0.changedFiles.isEmpty }
                .max { $0.createdAt < $1.createdAt }
            return waiting.map { .pendingChanges($0.id) }
        }
        if bot.folderBookmark != nil { return .needsWorkCopy(bot.folderName ?? bot.name) }
        if let repo = bot.repoSlugs.first { return .needsWorkCopy(repo) }
        return .noCode
    }

    var message: String {
        switch self {
        case .unpaired: "this app isn't paired with darkmux"
        case let .noRole(name): "\(name) has no darkmux role yet"
        case .noCode: "this bot has no code to work on yet: add a folder or a GitHub repo in its info"
        case let .needsWorkCopy(what): "\(what) needs a work copy on this Mac"
        case .notOnThisDevice: "runs start from the Mac app for now"
        case .pendingChanges: "the last run's changes are still waiting: keep or discard them first"
        }
    }
}
