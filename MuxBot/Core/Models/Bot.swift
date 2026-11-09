import Foundation
import SwiftData

/// Where a bot stands. Drives the Home grouping.
enum BotState: String, Codable, CaseIterable, Sendable {
    case needsYou, working, ready
}

/// The darkmux roles that do the work underneath a bot. Not bots and not
/// tiles: a bot names one on its dispatch card, and runs show it.
enum CrewRole: String, Codable, CaseIterable, Sendable {
    case coder, reviewer, evalRunner, researcher

    var name: String {
        switch self {
        case .coder: "Coder"
        case .reviewer: "Reviewer"
        case .evalRunner: "Eval runner"
        case .researcher: "Researcher"
        }
    }

    var systemImage: String {
        switch self {
        case .coder: "hammer"
        case .reviewer: "magnifyingglass"
        case .evalRunner: "gauge"
        case .researcher: "lightbulb"
        }
    }

    /// Words that suggest this crew role, for the keyword fallback.
    var keywords: [String] {
        switch self {
        case .coder: ["build", "code", "implement", "refactor", "change", "update", "write", "feature", "bugs", "crash"]
        case .reviewer: ["review", "check", "audit", "diff", "pull"]
        case .evalRunner: ["eval", "benchmark", "measure", "score", "sweep"]
        case .researcher: ["research", "investigate", "compare", "read", "papers", "summarize", "explore", "draft"]
        }
    }
}

/// A project or theme you name: a persona with its own thread and the
/// resources it works with. darkmux roles are its crew, not bots.
@Model
final class Bot {
    var id: UUID = UUID()
    var name: String = ""
    /// The persona: what this bot is about, in plain words. Routing reads it.
    var instructions: String = ""
    var systemImage: String = "sparkles"
    @Attribute(.externalStorage) var avatarImageData: Data?
    /// The bot's character (`BotLook`): animal, main color and LED eye
    /// color. Empty means "suggest one from the name" (`Bot.look`).
    var avatarAnimal: String = ""
    var bodyColorHex: String = ""
    var eyeColorHex: String = ""
    /// The use case it was started from (a template registry id, like
    /// "website"); empty for a bot made by hand.
    var useCaseId: String = ""
    /// Its skills, copied from the template's PLAYBOOK.md when it was made
    /// (JSON of `[BotSkill]`), so a later template never changes it.
    var skillsJSON: String = ""
    var state: BotState = BotState.ready
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \BotTask.bot)
    var tasks: [BotTask]? = []

    @Relationship(deleteRule: .cascade, inverse: \BotResource.bot)
    var resources: [BotResource]? = []

    @Relationship(deleteRule: .cascade, inverse: \BotRun.bot)
    var runs: [BotRun]? = []

    init(name: String, instructions: String, systemImage: String = "sparkles", state: BotState = BotState.ready) {
        self.name = name
        self.instructions = instructions
        self.systemImage = systemImage
        self.state = state
    }

    // MARK: This machine only (`LocalBotState`, never synced)

    /// This Mac's darkmux workspace for the bot (a name darkmux resolves
    /// under its worktrees; never a path) and the machine it's on.
    var workspaceName: String? {
        get { LocalBotState.shared[id]?.workspaceName }
        set { LocalBotState.shared.update(id) { $0.workspaceName = newValue } }
    }
    var workspaceMachine: String? {
        get { LocalBotState.shared[id]?.workspaceMachine }
        set { LocalBotState.shared.update(id) { $0.workspaceMachine = newValue } }
    }
    /// A local checkout you picked (security-scoped bookmark) and its
    /// folder name for display. darkmux makes a worktree of it.
    var folderBookmark: Data? {
        get { LocalBotState.shared[id]?.folderBookmark }
        set { LocalBotState.shared.update(id) { $0.folderBookmark = newValue } }
    }
    var folderName: String? {
        get { LocalBotState.shared[id]?.folderName }
        set { LocalBotState.shared.update(id) { $0.folderName = newValue } }
    }

    /// The newest task.
    var currentTask: BotTask? {
        (tasks ?? []).max { $0.createdAt < $1.createdAt }
    }

    var sortedResources: [BotResource] {
        (resources ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    /// A preview link you added (used when darkmux isn't running one).
    var previewURL: URL? {
        sortedResources.last { $0.kind == .previewURL }.flatMap { URL(string: $0.value) }
    }

    var repoSlugs: [String] {
        sortedResources.filter { $0.kind == .repo }.compactMap { GitHubIssue.repoSlug(from: $0.value) }
    }
}

enum ResourceKind: String, Codable, CaseIterable, Sendable {
    /// What you can add by typing: folders come from the Open panel
    /// (Add folder), so the app never holds a typed path.
    static var addable: [ResourceKind] { allCases.filter { $0 != .folder } }

    case repo, folder, preview, previewURL, link, note

    var label: String {
        switch self {
        case .repo: "Repo"
        case .folder: "Local folder"
        case .preview: "Preview recipe"
        case .previewURL: "Preview URL"
        case .link: "Link"
        case .note: "Note"
        }
    }

    var systemImage: String {
        switch self {
        case .repo: "arrow.triangle.branch"
        case .folder: "folder"
        case .preview: "play.rectangle"
        case .previewURL: "safari"
        case .link: "link"
        case .note: "note.text"
        }
    }

    /// Best guess for a pasted value: GitHub URLs are repos, other URLs
    /// links, paths folders (or a preview recipe), anything else a note.
    static func guess(for value: String) -> ResourceKind {
        let v = value.lowercased()
        if v.contains("github.com/") { return .repo }
        if v.contains(".ts.net") || v.contains("localhost") || v.contains("127.0.0.1") { return .previewURL }
        if v.hasPrefix("http://") || v.hasPrefix("https://") { return .link }
        if v.hasSuffix("preview.json") { return .preview }
        if v.hasPrefix("/") || v.hasPrefix("~/") { return .folder }
        return .note
    }
}

/// Something a bot works with: a repo, a folder, a preview recipe, a link
/// or a note.
@Model
final class BotResource {
    var id: UUID = UUID()
    var kind: ResourceKind = ResourceKind.note
    var value: String = ""
    var createdAt: Date = Date()
    var bot: Bot?

    init(kind: ResourceKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// A piece of work recorded on a bot. Local only until the fleet is wired.
@Model
final class BotTask {
    var id: UUID = UUID()
    var title: String = ""
    var why: String = ""
    /// The crew role it was dispatched to; nil for a bot-to-bot handoff.
    var crew: CrewRole?
    var createdAt: Date = Date()
    var bot: Bot?

    init(title: String, why: String, crew: CrewRole? = nil) {
        self.title = title
        self.why = why
        self.crew = crew
    }
}

extension Bot {
    /// The skills copied from its playbook (`skillsJSON`).
    var skills: [BotSkill] {
        get { (try? JSONDecoder().decode([BotSkill].self, from: Data(skillsJSON.utf8))) ?? [] }
        set { skillsJSON = newValue.isEmpty ? "" : (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "" }
    }
}
