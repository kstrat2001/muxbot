import Foundation

/// "Work on a project I already have": the built-in use case for your own
/// code, a folder on this Mac or a repo on your GitHub. It has no template:
/// the bot's skills come from the project's own PLAYBOOK.md when it has one
/// (schema 1), else the general ones built into the app. The bot keeps the
/// repo, never a path; a folder's bookmark stays on this Mac
/// (`LocalBotState`).
@MainActor
enum ExistingProject {
    static let id = "existing"
    static let title = String(localized: "Work on a project I already have")
    nonisolated static let icon = "folder.badge.gearshape"
    static let summary = String(localized: "Point Mux Bot at your code, on this Mac or on GitHub, and keep improving it.")

    /// Where the code is.
    enum Source: Equatable {
        /// A folder you picked on this Mac (its repo comes from `origin`).
        case folder(URL)
        /// A repo on your GitHub; `checkout` is a bookmark of your own copy
        /// of it on this Mac, when another bot already has one.
        case github(repo: String, checkout: Checkout?)
    }

    /// Your own checkout of a repo, from a bot that already points at it.
    struct Checkout: Equatable {
        var bookmark: Data
        var folderName: String
    }

    /// Where the bot's skills came from.
    enum SkillsSource: Equatable {
        case projectPlaybook, general
        /// The project has a PLAYBOOK.md that can't be used, and why.
        case invalid(String)
    }

    /// Start needs a name and a purpose, and waits for the project's
    /// PLAYBOOK.md to be read, so a quick tap never gets general skills.
    static func canStart(name: String, purpose: String, starting: Bool, readingPlaybook: Bool) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !starting && !readingPlaybook
    }

    /// "kstrat2001/darkly-energized" → "Darkly Energized".
    nonisolated static func suggestedName(repo: String) -> String {
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let words = name.split(whereSeparator: { "-_. ".contains($0) })
        guard !words.isEmpty else { return name }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The project's own PLAYBOOK.md when it parses, else the general one,
    /// with why the project's can't be used.
    static func playbook(projectText: String?) -> (Playbook, SkillsSource) {
        guard let projectText else { return (general, .general) }
        do {
            return (try Playbook.parse(projectText), .projectPlaybook)
        } catch let error as Playbook.ParseError {
            return (general, .invalid(error.projectMessage))
        } catch {
            return (general, .invalid(error.localizedDescription))
        }
    }

    static var general: Playbook {
        guard let url = Bundle.main.url(forResource: "\(id).PLAYBOOK", withExtension: "md", subdirectory: "Templates")
                ?? Bundle.main.url(forResource: "\(id).PLAYBOOK", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let playbook = try? Playbook.parse(text) else {
            return Playbook(title: title, icon: icon, pitch: summary, crew: [.coder], questions: [],
                            persona: "You look after {name}, a project that already exists. You make the change that was asked for, nothing more.",
                            skills: [])
        }
        return playbook
    }

    /// Your own checkout of `repo` on this Mac, if another bot has one.
    static func knownCheckout(for repo: String, among bots: [Bot]) -> Checkout? {
        for bot in bots where bot.repoSlugs.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) {
            if let bookmark = bot.folderBookmark, !bookmark.isEmpty {
                return Checkout(bookmark: bookmark, folderName: bot.folderName ?? repo)
            }
        }
        return nil
    }

    /// Makes the bot from the source and your answers, then has darkmux set
    /// up its work copy: a worktree of your checkout, or a clone of the repo.
    /// Returns the bot and, for a folder that can't be used, why.
    static func start(_ source: Source, name: String, purpose: String, projectPlaybook: String?, playbookError: String? = nil, look: BotLook? = nil,
                      store: BotStore, runs: RunCoordinator) async -> (bot: Bot, problem: String?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playbook = self.playbook(projectText: projectPlaybook).0
        let skillsSource = skills(playbook: projectPlaybook, error: playbookError)
        let bot = store.add(name: name, instructions: StartProject.instructions(playbook, answers: .init(name: name, purpose: purpose), name: name),
                            systemImage: playbook.icon)
        bot.look = look ?? BotLook.fresh(avoiding: store.allBots().filter { $0.id != bot.id }.map(\.look))
        bot.skills = playbook.skills
        store.save()
        let thread = store.conversation(for: .bot(bot.id))
        var problem: String?
        switch source {
        case let .folder(url):
            problem = await runs.addFolder(url, to: bot, store: store)
        case let .github(repo, checkout):
            store.addResource(.repo, "https://github.com/\(repo)", to: bot)
            if let checkout {
                bot.folderBookmark = checkout.bookmark
                bot.folderName = checkout.folderName
            }
            store.save()
            await runs.setUpWorkCopy(for: bot, store: store)
        }
        store.append(.assistant, greeting(name: name, source: source, skills: skillsSource, madeHere: bot.workspaceName != nil), to: thread)
        return (bot, problem)
    }

    static func greeting(name: String, source: Source, skills: SkillsSource, madeHere: Bool = true) -> String {
        var parts = [String(localized: "Hi, I'm \(name). Tell me what to change, or point at something in the preview.")]
        if !madeHere {
            parts.append(String(localized: "darkmux sets up my work copy once Mux Bot is paired with it on your Mac."))
        } else if case .github(_, nil) = source {
            parts.append(String(localized: "darkmux cloned this repo, and a clone gets no preview: darkmux runs a preview only from your own checkout. Add your checkout with Add folder in my info to see one."))
        }
        switch skills {
        case .projectPlaybook: parts.append(String(localized: "My skills come from this project's PLAYBOOK.md."))
        case .general: parts.append(String(localized: "This project has no PLAYBOOK.md, so I start with general skills."))
        case let .invalid(why): parts.append(String(localized: "\(why) So I start with general skills."))
        }
        return parts.joined(separator: " ")
    }
}

/// A repo from your GitHub account, for the picker.
struct GitHubRepoSummary: Decodable, Equatable, Identifiable, Sendable {
    var fullName: String
    var isPrivate: Bool
    var description: String?
    var id: String { fullName }

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case isPrivate = "private"
        case description
    }
}

extension ExistingProject {
    /// A repo's PLAYBOOK.md: its text, none, or a read that failed (never
    /// taken as "none", so no PLAYBOOK card is offered over a real one).
    enum PlaybookFetch: Equatable {
        case text(String), none, failed(String)
        var isFailure: Bool { if case .failed = self { true } else { false } }
        var text: String? { if case let .text(t) = self { t } else { nil } }
        var problem: String? { if case let .failed(why) = self { why } else { nil } }
    }

    static func fetchPlaybook(repo: String, github: any GitHubClient) async -> PlaybookFetch {
        do {
            guard let data = try await github.file(repo: repo, path: "PLAYBOOK.md") else { return .none }
            return String(data: data, encoding: .utf8).map { .text($0) } ?? .none
        } catch {
            return .failed(String(localized: "I couldn't read this project's PLAYBOOK.md from GitHub: \(error.localizedDescription)"))
        }
    }

    /// Where the skills come from, given the PLAYBOOK.md read (or why it
    /// couldn't be).
    static func skills(playbook text: String?, error: String?) -> SkillsSource {
        if let error { return .invalid(error) }
        return playbook(projectText: text).1
    }
}
