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

    @MainActor
    static func check(paired: Bool, crew: CrewRole, bot: Bot) -> RunBlocker? {
        #if os(iOS)
        return .notOnThisDevice
        #else
        guard paired else { return .unpaired }
        guard crew.darkmuxRole != nil else { return .noRole(crew.name) }
        if bot.workspaceName != nil { return nil }
        if bot.folderBookmark != nil { return .needsWorkCopy(bot.folderName ?? bot.name) }
        if let repo = bot.repoSlugs.first { return .needsWorkCopy(repo) }
        return .noCode
        #endif
    }

    var message: String {
        switch self {
        case .unpaired: "this app isn't paired with darkmux"
        case let .noRole(name): "\(name) has no darkmux role yet"
        case .noCode: "this bot has no code to work on yet: add a folder or a GitHub repo in its info"
        case let .needsWorkCopy(what): "\(what) needs a work copy on this Mac"
        case .notOnThisDevice: "runs start from the Mac app for now"
        }
    }
}
