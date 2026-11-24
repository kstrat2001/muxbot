import Foundation

/// "Put it on GitHub" for a project that started on this Mac only: the same
/// step as starting with Back up to GitHub on. An empty repo in your account
/// (private unless you choose public), then darkmux pushes the project's own
/// history into it (darkmux #3681), so GitHub and this Mac share one history.
/// Later work is backed up there after each change.
@MainActor
enum PutOnGitHub {
    /// Only a template project with a work copy here and no repo yet.
    static func canPut(_ bot: Bot) -> Bool {
        !bot.useCaseId.isEmpty && bot.repoSlugs.isEmpty && bot.workspaceName != nil && pendingRepo(bot) == nil
    }

    /// The repo Put made that darkmux hasn't pushed the project into yet,
    /// shared with your other devices (`ModelSettingsStore.pendingRepo`).
    static func pendingRepo(_ bot: Bot) -> String? { ModelSettingsStore.shared.pendingRepo(bot: bot.id) }

    /// Sends the project into `repo` (tests); else darkmux's push.
    typealias Push = @MainActor (Bot, String) async throws -> DarkmuxClient.GitPushed?

    /// Put made the repo but the work isn't in it yet: Put finishes into
    /// that repo, never a second one.
    static func canResume(_ bot: Bot) -> Bool {
        bot.workspaceName != nil && pendingRepo(bot) != nil
    }

    static func run(_ bot: Bot, isPublic: Bool, github: GitHubRepoMaker, token: String,
                    store: BotStore, runs: RunCoordinator) async throws -> GitHubRepoMaker.Made {
        let wanted = GitHubRepoMaker.slug(bot.name)
        return try await run(bot, isPublic: isPublic, make: {
            let owner = try await github.login()
            let name = try await github.freeName(wanted, owner: owner)
            return try await github.make(name: name, isPrivate: !isPublic, description: "")
        }, push: { bot, repo in
            try await runs.pushTask(bot, store: store, github: token, repo: repo)
        }, store: store, runs: runs)
    }

    /// Makes the empty repo (`make`), keeps it as the pending repo at once
    /// (shared with your other devices), then has darkmux push the project
    /// into it. Only once the push landed is it the bot's repo. A push that
    /// fails leaves it pending, so Put again (on any device) finishes into
    /// it; one that landed though the answer was lost is just recorded.
    static func run(_ bot: Bot, isPublic: Bool, make: @escaping @MainActor () async throws -> GitHubRepoMaker.Made, push: @escaping Push,
                    store: BotStore, runs: RunCoordinator) async throws -> GitHubRepoMaker.Made {
        let resuming = canResume(bot)
        guard resuming || canPut(bot) else {
            throw GitHubRepoMaker.Failure.plain(String(localized: "This project is already on GitHub, or isn't on this Mac."))
        }
        guard !runs.puttingOnGitHub.contains(bot.id) else {
            throw GitHubRepoMaker.Failure.plain(String(localized: "It's already being put on GitHub."))
        }
        runs.puttingOnGitHub.insert(bot.id)
        defer { runs.puttingOnGitHub.remove(bot.id) }
        // What Put pushes is the work as of now: a run finishing meanwhile
        // isn't in it, so it's backed up after and still offered for a review.
        let readAt = Date()
        let made: GitHubRepoMaker.Made
        if resuming, let repo = pendingRepo(bot) {
            made = .init(repo: repo, url: URL(string: "https://github.com/\(repo)")!)
        } else {
            made = try await make()
            // Kept as soon as it exists: a failed push next never leaves a
            // repo this app forgot, and trying again makes no second one.
            ModelSettingsStore.shared.setPendingRepo(made.repo, bot: bot.id)
        }
        // A push that landed though its answer was lost: the work copy has
        // that remote already, so there's nothing to send again.
        let landed = (try? await runs.taskStatus(bot))?.origin == "github.com/\(made.repo)"
        if !landed {
            do {
                _ = try await push(bot, made.repo)
            } catch {
                throw GitHubRepoMaker.Failure.notPushedYet(repo: made.repo, why: RunCoordinator.plain(error).sentence)
            }
        }
        store.addResource(.repo, "https://github.com/\(made.repo)", to: bot)
        ModelSettingsStore.shared.setPendingRepo(nil, bot: bot.id)
        LocalBotState.shared.update(bot.id) { $0.shippedThrough = readAt }
        store.save()
        store.append(.system, String(localized: "Put on GitHub: \(made.url.absoluteString). New work is backed up there after each change."),
                     to: store.conversation(for: .bot(bot.id)))
        if (bot.runs ?? []).contains(where: { $0.keptCommit != nil && ($0.finishedAt ?? .distantPast) > readAt }) {
            await runs.backUp(bot, store: store)
        }
        return made
    }
}

extension PutOnGitHub {
    /// What Bot info says when putting it on GitHub fails: darkmux's
    /// refusals plainly, the app's and GitHub's own words as they are.
    static func problem(_ error: any Error) -> String { RunCoordinator.plain(error).sentence }
}
