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
    /// Preferred local model. Empty means the default.
    var modelName: String = ""
    var systemImage: String = "sparkles"
    @Attribute(.externalStorage) var avatarImageData: Data?
    var state: BotState = BotState.ready
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \BotTask.bot)
    var tasks: [BotTask]? = []

    @Relationship(deleteRule: .cascade, inverse: \BotResource.bot)
    var resources: [BotResource]? = []

    @Relationship(deleteRule: .cascade, inverse: \BotRun.bot)
    var runs: [BotRun]? = []

    init(name: String, instructions: String, modelName: String = "", systemImage: String = "sparkles", state: BotState = BotState.ready) {
        self.name = name
        self.instructions = instructions
        self.modelName = modelName
        self.systemImage = systemImage
        self.state = state
    }

    /// The newest task.
    var currentTask: BotTask? {
        (tasks ?? []).max { $0.createdAt < $1.createdAt }
    }

    var sortedResources: [BotResource] {
        (resources ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    /// Where to watch this bot's work: the newest run's live URL, else a
    /// preview URL resource (today a temporary test server).
    var previewURL: URL? {
        let fromRun = (runs ?? []).sorted { $0.createdAt < $1.createdAt }.last?.previewURL
        let fromResource = sortedResources.last { $0.kind == .previewURL }?.value
        return (fromRun ?? fromResource).flatMap(URL.init(string:))
    }

    var repoSlugs: [String] {
        sortedResources.filter { $0.kind == .repo }.compactMap { GitHubIssue.repoSlug(from: $0.value) }
    }
}

enum ResourceKind: String, Codable, CaseIterable, Sendable {
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
