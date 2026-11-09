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

    static func run(_ bot: Bot, isPublic: Bool, github: GitHubRepoMaker, pr: GitHubPR,
                    store: BotStore, runs: RunCoordinator) async throws -> GitHubRepoMaker.Made {
        guard canPut(bot), let workspace = bot.workspaceName else {
            throw GitHubRepoMaker.Failure.github(String(localized: "This project is already on GitHub, or isn't on this Mac."))
        }
        guard let entry = await runs.template(for: bot.useCaseId) else {
            throw GitHubRepoMaker.Failure.template(String(localized: "its template (\(bot.useCaseId)) isn't in the template list anymore"))
        }
        let changes = try await runs.changes(for: workspace)
        let owner = try await github.login()
        let name = try await github.freeName(GitHubRepoMaker.slug(bot.name), owner: owner)
        let made = try await github.make(name: name, isPrivate: !isPublic, description: "", from: entry)
        // The project's own work goes onto the default branch, on top of the
        // template's commit (which this Mac wrote, so it may move it).
        if !changes.files.isEmpty {
            pr.local.update(bot.id) { $0.pushedHeads = ($0.pushedHeads ?? [:]).merging([made.defaultBranch: made.startCommit]) { $1 } }
            do {
                _ = try await pr.push(changes, repo: made.repo, message: String(localized: "\(bot.name)'s work so far"), bot: bot.id,
                                      start: GitHubPR.Start(commit: made.startCommit, branch: made.defaultBranch, head: made.defaultBranch))
            } catch {
                throw GitHubRepoMaker.Failure.madeButNotFilled(repo: made.repo, why: error.localizedDescription)
            }
        }
        store.addResource(.repo, "https://github.com/\(made.repo)", to: bot)
        bot.githubStart = GitHubPR.Start(commit: made.startCommit, branch: made.defaultBranch, head: "mux/\(GitHubRepoMaker.slug(bot.name))")
        store.save()
        store.append(.system, String(localized: "Put on GitHub: \(made.url.absoluteString). New work is backed up to \(bot.githubStart?.head ?? "its branch") there."),
                     to: store.conversation(for: .bot(bot.id)))
        return made
    }
}
