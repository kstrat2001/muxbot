import Foundation

/// Why a dispatch card can't start yet; the card offers the fix.
enum RunBlocker: Equatable, Sendable {
    /// The app isn't paired with darkmux on this Mac.
    case unpaired
    /// This crew role has no darkmux role yet.
    case noRole(String)
    /// The bot has no repo or folder to work in.
    case noCode
    /// A bot started from a template whose project isn't made on this Mac
    /// yet (made while unpaired, or on iPhone). `here`: this device can make
    /// it now.
    case projectNotMade(String, here: Bool)
    /// The bot has code ("owner/repo" or a folder name) but no workspace on
    /// this Mac yet: the card offers to set one up.
    case needsWorkCopy(String)
    /// Runs start from the Mac app until phone pairing exists.
    case notOnThisDevice
    /// Another run is still working in the bot's work copy.
    case runWorking(UUID)
    /// The chosen model's server doesn't answer (LM Studio open with its
    /// local server off): the run would fail at once, so it isn't sent.
    case modelServerOff(String)

    /// Runs start only from the Mac app until phone pairing exists.
    #if os(iOS)
    static let deviceRuns = false
    #else
    static let deviceRuns = true
    #endif

    @MainActor
    static func check(paired: Bool, crew: CrewRole, bot: Bot, deviceRuns: Bool = deviceRuns, excluding run: UUID? = nil) -> RunBlocker? {
        // A template bot with no project here, backed up to GitHub or not:
        // it's made from its template, never cloned from its own repo.
        let templateOnly = !bot.useCaseId.isEmpty && bot.workspaceName == nil && bot.folderBookmark == nil
        guard deviceRuns else { return templateOnly ? .projectNotMade(bot.name, here: false) : .notOnThisDevice }
        guard paired else { return .unpaired }
        if templateOnly { return .projectNotMade(bot.name, here: true) }
        guard crew.darkmuxRole != nil else { return .noRole(crew.name) }
        if bot.workspaceName != nil {
            // Finished runs are committed, so only a run still working blocks.
            // Only a run in this Mac's work copy (another Mac's runs are in its own).
            let working = (bot.runs ?? []).first { $0.id != run && $0.phase == .running && $0.startedHere }
            return working.map { .runWorking($0.id) }
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
        case let .projectNotMade(name, here: true): "\(name)'s project isn't made on this Mac yet"
        case let .projectNotMade(name, here: false):
            "\(name)'s project is made on your Mac, from its template, once Mux Bot there is paired with darkmux. Open \(name) in Mux Bot on your Mac"
        case let .needsWorkCopy(what): "\(what) needs a work copy on this Mac"
        case .notOnThisDevice: "runs start from the Mac app for now"
        case .runWorking: "a run is still working in this bot's work copy: wait for it, or stop it"
        case let .modelServerOff(engine) where engine == "LM Studio":
            "LM Studio's local server is off, so the model can't answer. Turn on its server in LM Studio (or pick another model with Change)"
        case let .modelServerOff(engine): "\(engine) isn't answering, so the model can't run. Start it, or pick another model with Change"
        }
    }
}
