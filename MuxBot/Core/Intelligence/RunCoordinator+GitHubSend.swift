import Foundation

/// Sending a task's work to GitHub through darkmux (muxbot#144 step 3):
/// darkmux pushes the task's branch from the work copy with plain git
/// (darkmux #3681), with your GitHub sign-in handed over for that one push
/// and never kept. The app keeps no record of its own of what it pushed:
/// darkmux's `status` says what GitHub has (`ahead`), the same on every
/// device.
extension RunCoordinator {
    /// A refusal the app words itself.
    struct SendRefused: LocalizedError, Equatable {
        var sentence: String
        var errorDescription: String? { sentence }
    }

    static var darkmuxNeedsUpdate: String {
        String(localized: "darkmux on the Mac needs an update before it can send changes to GitHub.")
    }

    /// A project an earlier Mux Bot put on GitHub: its copy here and the one
    /// on GitHub started apart, so it can't be sent there as it is.
    static var fromAnEarlierMuxBot: String {
        String(localized: "This project was put on GitHub by an earlier Mux Bot. To keep working on it, start it again from GitHub. Changes made here since its last backup stay in the old copy on this Mac.")
    }

    /// darkmux's view of the task's work copy, read now, and kept for
    /// `TaskState` (this launch).
    func taskStatus(_ bot: Bot) async throws -> DarkmuxClient.GitStatus {
        guard let workspace = bot.workspaceName else { throw SendRefused(sentence: RunBlocker.noCode.message) }
        let read = gitStatusSource ?? { [connection] workspace in
            guard let connection, let token = connection.token else { throw NotPaired() }
            return try await connection.client.gitStatus(token: token, workspace: workspace)
        }
        do {
            let status = try await read(workspace)
            taskStatuses[bot.id] = status
            taskStatusUnreachable.remove(bot.id)
            return status
        } catch let error as URLError where error.code != .cancelled {
            taskStatusUnreachable.insert(bot.id)
            throw DarkmuxClient.Unreachable(underlying: error)
        }
    }

    /// `taskStatus`, its failure only remembered.
    @discardableResult
    func refreshTaskStatus(_ bot: Bot) async -> DarkmuxClient.GitStatus? {
        try? await taskStatus(bot)
    }

    /// Sends the task's branch to GitHub through darkmux. Nothing is sent
    /// when GitHub has it all already, unless `force` (opening a review). A
    /// project made from a template goes to `repo`, an empty repository, the
    /// first time.
    @discardableResult
    func pushTask(_ bot: Bot, store: BotStore, github: String, repo: String? = nil, force: Bool = false) async throws -> DarkmuxClient.GitPushed? {
        guard let workspace = bot.workspaceName else { throw SendRefused(sentence: RunBlocker.noCode.message) }
        if gitPusher == nil, !(await capabilities()).contains("git_route") { throw SendRefused(sentence: Self.darkmuxNeedsUpdate) }
        let status = try await taskStatus(bot)
        if repo == nil, status.origin == nil, !bot.repoSlugs.isEmpty {
            offerStartFromGitHub(bot, store: store)
            throw SendRefused(sentence: Self.fromAnEarlierMuxBot)
        }
        if !force, repo == nil, (status.ahead ?? status.pending) == 0 { return nil }
        let push = gitPusher ?? { [connection] workspace, github, repo in
            guard let connection, let token = connection.token else { throw NotPaired() }
            return try await connection.client.gitPush(token: token, workspace: workspace, github: github, repo: repo)
        }
        let pushed = try await push(workspace, github, repo)
        await refreshTaskStatus(bot)
        return pushed
    }

    /// The card for a project from an earlier Mux Bot, once per bot this
    /// launch.
    func offerStartFromGitHub(_ bot: Bot, store: BotStore) {
        guard let repo = bot.repoSlugs.first, !offeredStartFromGitHub.contains(bot.id) else { return }
        offeredStartFromGitHub.insert(bot.id)
        store.proposeAction(.startFromGitHub(repo: repo), in: .bot(bot.id))
    }

    /// A new work copy of the bot's repo from GitHub. The old one stays in
    /// darkmux, with whatever it holds that GitHub doesn't.
    func startAgainFromGitHub(_ bot: Bot, store: BotStore) async {
        bot.workspaceName = nil
        taskStatuses[bot.id] = nil
        store.save()
        await setUpWorkCopy(for: bot, store: store)
        if case let .failed(why)? = workCopySetup[bot.id] {
            store.append(.system, String(localized: "darkmux couldn't set up a copy from GitHub: \(why)"), to: store.conversation(for: .bot(bot.id)))
        } else {
            store.append(.system, String(localized: "Started again from GitHub. The old copy stays on this Mac in darkmux."), to: store.conversation(for: .bot(bot.id)))
        }
    }

    /// A file you approved (a preview recipe, a playbook) is saved in the
    /// task's work copy too, as its own change (darkmux #3688), so it goes
    /// to GitHub with the task's other changes and its Undo takes it out.
    func saveApproved(_ path: String, data: Data, bot: Bot, store: BotStore) async {
        let thread = store.conversation(for: .bot(bot.id))
        guard let workspace = bot.workspaceName else { return }
        let add = fileAdder ?? { [connection] workspace, path, data in
            guard let connection, let token = connection.token else { throw NotPaired() }
            return try await connection.client.addFile(token: token, workspace: workspace, path: path, data: data)
        }
        let canAdd = fileAdder != nil ? true : (await capabilities()).contains("workspace_file")
        guard canAdd else {
            store.append(.system, String(localized: "darkmux on the Mac needs an update before \(path) can go into a review with this project's changes."), to: thread)
            return
        }
        do {
            let saved = try await add(workspace, path, data)
            if saved.workId != nil {
                store.append(.system, String(localized: "Saved \(path) with this project's changes, so it goes into its next review."), to: thread)
                await sendToGitHub(bot, store: store)
            }
        } catch {
            let said = Self.plain(error)
            let line = store.append(.system, String(localized: "Couldn't save \(path) with this project's changes: \(said.sentence)"), to: thread)
            messageDetails[line.id] = said.details
        }
    }
}
