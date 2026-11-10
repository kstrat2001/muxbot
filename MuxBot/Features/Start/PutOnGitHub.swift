import Foundation

/// "Put it on GitHub" for a project that started on this Mac only: the same
/// step as starting with Back up to GitHub on. A repo in your account
/// (private unless you choose public) with the template's files at its
/// pinned commit, then the project's committed work on top of its default
/// branch, so the repo holds the project's latest files. Later work is
/// backed up to `mux/<bot>`.
@MainActor
enum PutOnGitHub {
    /// Only a template project with a work copy here and no repo yet.
    static func canPut(_ bot: Bot) -> Bool {
        !bot.useCaseId.isEmpty && bot.repoSlugs.isEmpty && bot.workspaceName != nil && bot.githubStart == nil
    }

    /// Pushes the project's work (tests); else `GitHubPR.push`.
    typealias Push = (DarkmuxClient.Changes, String, String, UUID, GitHubPR.Start?) async throws -> GitHubPR.Pushed

    /// Put made the repo but the work isn't in it yet: Put finishes into
    /// that repo, never a second one.
    static func canResume(_ bot: Bot) -> Bool {
        LocalBotState.shared[bot.id]?.putPending == true && bot.githubStart != nil && bot.workspaceName != nil && !bot.repoSlugs.isEmpty
    }

    static func run(_ bot: Bot, isPublic: Bool, github: GitHubRepoMaker, pr: GitHubPR,
                    store: BotStore, runs: RunCoordinator) async throws -> GitHubRepoMaker.Made {
        let useCase = bot.useCaseId, wanted = GitHubRepoMaker.slug(bot.name)
        return try await run(bot, isPublic: isPublic, make: {
            guard let entry = await runs.template(for: useCase) else {
                throw GitHubRepoMaker.Failure.template(String(localized: "its template (\(useCase)) isn't in the template list anymore"))
            }
            let owner = try await github.login()
            let name = try await github.freeName(wanted, owner: owner)
            return try await github.make(name: name, isPrivate: !isPublic, description: "", from: entry)
        }, push: { try await pr.push($0, repo: $1, message: $2, bot: $3, start: $4) }, local: pr.local, store: store, runs: runs)
    }

    /// Makes the repo (`make`), records it at once, then pushes the
    /// project's committed work onto its default branch. A push that fails
    /// leaves the repo recorded, so Put again resumes into it. Once the work
    /// is there, `mux/<bot>` builds on that commit and the runs it holds
    /// aren't offered for a PR again.
    /// `local` is where the push reads the commit this Mac last wrote to
    /// each branch (the push's own).
    static func run(_ bot: Bot, isPublic: Bool, make: @escaping () async throws -> GitHubRepoMaker.Made, push: @escaping Push,
                    local: LocalBotState = .shared, store: BotStore, runs: RunCoordinator) async throws -> GitHubRepoMaker.Made {
        let resuming = canResume(bot)
        guard resuming || canPut(bot), let workspace = bot.workspaceName else {
            throw GitHubRepoMaker.Failure.plain(String(localized: "This project is already on GitHub, or isn't on this Mac."))
        }
        guard !runs.puttingOnGitHub.contains(bot.id) else {
            throw GitHubRepoMaker.Failure.plain(String(localized: "It's already being put on GitHub."))
        }
        runs.puttingOnGitHub.insert(bot.id)
        defer { runs.puttingOnGitHub.remove(bot.id) }
        let changes = try await runs.changes(for: workspace)
        let made: GitHubRepoMaker.Made
        if resuming, let start = bot.githubStart, let repo = bot.repoSlugs.first {
            made = .init(repo: repo, url: URL(string: "https://github.com/\(repo)")!, defaultBranch: start.branch, startCommit: start.commit)
        } else {
            made = try await make()
            // Recorded as soon as it exists: a failed push next never leaves
            // a repo this app forgot, and trying again makes no second one.
            store.addResource(.repo, "https://github.com/\(made.repo)", to: bot)
            bot.githubStart = GitHubPR.Start(commit: made.startCommit, branch: made.defaultBranch, head: "mux/\(GitHubRepoMaker.slug(bot.name))")
            // The template's commit is this Mac's, so the work may go on top of it.
            LocalBotState.shared.update(bot.id) { $0.putPending = true }
            local.update(bot.id) { $0.pushedHeads = ($0.pushedHeads ?? [:]).merging([made.defaultBranch: made.startCommit]) { $1 } }
            store.save()
        }
        var workCommit = made.startCommit
        if !changes.files.isEmpty {
            do {
                workCommit = try await push(changes, made.repo, String(localized: "\(bot.name)'s work so far"), bot.id,
                                            GitHubPR.Start(commit: made.startCommit, branch: made.defaultBranch, head: made.defaultBranch)).commit
            } catch {
                throw GitHubRepoMaker.Failure.notPushedYet(repo: made.repo, why: error.localizedDescription)
            }
        }
        // Later work builds on the pushed work, so a PR from mux/<bot> shows
        // only what's new; the runs already pushed aren't offered again.
        bot.githubStart?.commit = workCommit
        LocalBotState.shared.update(bot.id) { $0.putPending = nil; $0.shippedThrough = Date() }
        store.save()
        store.append(.system, String(localized: "Put on GitHub: \(made.url.absoluteString). New work is backed up to \(bot.githubStart?.head ?? "its branch") there."),
                     to: store.conversation(for: .bot(bot.id)))
        return made
    }
}
