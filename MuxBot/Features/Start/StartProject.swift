import Foundation

/// Starting a project from a use case: a new bot made from the template's
/// playbook (persona, look, skills), then darkmux sets up its workspace on
/// this Mac from the template at its pinned ref, local only (no remote)
/// until it goes to GitHub. Reads only the entry and its playbook: no use
/// case has code of its own.
@MainActor
enum StartProject {
    struct Answers: Equatable {
        var name: String
        var purpose: String = ""
        var style: String = ""
        /// On by default: the project gets its own GitHub repo too. Off, it
        /// stays on this Mac.
        var backUpToGitHub: Bool = true
        /// The new GitHub repo's name (from the project's when blank).
        var repoName: String = ""
        /// The repo is private unless you switch Public on.
        var isPublic: Bool = false

        /// The first run is built from what it's for, so both are needed.
        var canStart: Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// With "Back up to GitHub" on (the default), the project's own GitHub
    /// repo comes first
    /// (private unless you chose public, filled with the template's files at
    /// its pinned commit), and only then the bot and the local project from
    /// the same commit. When the GitHub step fails nothing is made here, and
    /// the error says why (naming a repo that was made but couldn't be
    /// filled). Off, it's the bot and darkmux's local project only.
    static func start(_ entry: TemplateEntry, playbook: Playbook, answers: Answers, look: BotLook? = nil,
                      github: GitHubRepoMaker?, store: BotStore, runs: RunCoordinator) async throws -> Bot {
        guard answers.backUpToGitHub else {
            return await start(entry, playbook: playbook, answers: answers, look: look, store: store, runs: runs)
        }
        guard let github else { throw GitHubRepoMaker.Failure.plain(String(localized: "Sign in with GitHub to back the project up there, or switch Back up to GitHub off.")) }
        let name = answers.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = try await github.login()
        let wanted = GitHubRepoMaker.slug(answers.repoName.isEmpty ? name : answers.repoName)
        let repoName = try await github.freeName(wanted, owner: owner)
        let made = try await github.make(name: repoName, isPrivate: !answers.isPublic,
                                         description: answers.purpose.trimmingCharacters(in: .whitespacesAndNewlines),
                                         from: entry)
        let bot = await start(entry, playbook: playbook, answers: answers, look: look, store: store, runs: runs) { bot in
            store.addResource(.repo, "https://github.com/\(made.repo)", to: bot)
            bot.githubStart = GitHubPR.Start(commit: made.startCommit, branch: made.defaultBranch,
                                             head: "mux/\(GitHubRepoMaker.slug(name))")
        }
        return bot
    }

    /// Makes the bot and asks darkmux for its workspace. The bot exists even
    /// if the workspace fails; its thread says why and it can be retried.
    @discardableResult
    static func start(_ entry: TemplateEntry, playbook: Playbook, answers: Answers, look: BotLook? = nil,
                      store: BotStore, runs: RunCoordinator, before: (Bot) -> Void = { _ in }) async -> Bot {
        let name = answers.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bot = store.add(name: name, instructions: instructions(playbook, answers: answers, name: name),
                            systemImage: playbook.icon)
        // The look you saw on the form (else a fresh one, unlike the bots you
        // have); a template's animal and colors no longer set it.
        bot.look = look ?? BotLook.fresh(avoiding: store.allBots().filter { $0.id != bot.id }.map(\.look))
        bot.useCaseId = entry.id
        bot.skills = playbook.skills
        before(bot)
        store.save()
        // The bot says hello in its own words, then offers its first run,
        // written from your answers, behind Approve.
        let first = playbook.firstRunTask(name: name, purpose: answers.purpose, feel: answers.style)
        store.append(.assistant, BotGreeting.started(name: name, hasFirstRun: first != nil),
                     to: store.conversation(for: .bot(bot.id)))
        let run = first.map { store.proposeRun(task: $0, crew: playbook.crew.first ?? .coder, on: bot) }
        await runs.setUpWorkCopy(for: bot, store: store, template: entry)
        if let run { await runs.chooseProfile(for: run) }
        return bot
    }

    /// The persona, then what you said it's for and how it should feel.
    static func instructions(_ playbook: Playbook, answers: Answers, name: String) -> String {
        var parts = [playbook.persona(for: name)]
        let purpose = answers.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = answers.style.trimmingCharacters(in: .whitespacesAndNewlines)
        if !purpose.isEmpty { parts.append("It's for: \(purpose)") }
        if !style.isEmpty { parts.append("How it should feel: \(style)") }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
