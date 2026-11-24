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

    /// darkmux didn't answer what it can do, so nothing is sent yet.
    static var darkmuxNotAnswering: String {
        String(localized: "darkmux on the Mac isn't answering right now, so nothing was sent to GitHub. It's sent once darkmux answers again.")
    }

    /// A project an earlier Mux Bot put on GitHub: its copy here and the one
    /// on GitHub started apart, so it can't be sent there as it is.
    static var fromAnEarlierMuxBot: String {
        String(localized: "This project was put on GitHub by an earlier Mux Bot. To keep working on it, start it again from GitHub. Changes made here since its last backup stay in the old copy on this Mac.")
    }

    // MARK: Status

    /// darkmux's view of the task's work copy, read now, and kept for
    /// `TaskState`. Each read replaces every fact: busy comes only from it.
    /// No answer from darkmux (no connection, or the tailnet entry's 502 or
    /// 503) reads as offline; any other answer means darkmux is there.
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
        } catch let error as DarkmuxClient.ClientError {
            if Self.noAnswer(error) { taskStatusUnreachable.insert(bot.id) } else { taskStatusUnreachable.remove(bot.id) }
            throw error
        }
    }

    /// darkmux didn't answer (the tailnet entry said so for it).
    nonisolated static func noAnswer(_ error: DarkmuxClient.ClientError) -> Bool {
        [502, 503].contains(error.status) || error.code == "unavailable"
    }

    /// `taskStatus`, its failure only remembered. Then, while GitHub lacks
    /// something of a task in review or a backed-up project, it's sent
    /// (`resendIfDue`).
    @discardableResult
    func refreshTaskStatus(_ bot: Bot, store: BotStore? = nil) async -> DarkmuxClient.GitStatus? {
        let status = try? await taskStatus(bot)
        if let status, let store { resendIfDue(bot, status: status, store: store) }
        return status
    }

    /// How often a thread on screen asks darkmux again: other devices change
    /// the work copy too.
    static let statusWatchBusy: Duration = .seconds(5)
    static let statusWatchIdle: Duration = .seconds(30)

    /// Keeps the bot's status fresh while its thread is on screen
    /// (`enterThread` starts it, leaving ends it).
    func watchStatus(_ bot: Bot, store: BotStore) {
        statusWatches[bot.id]?.cancel()
        statusWatches[bot.id] = Task { [weak self] in
            while let self, !Task.isCancelled, self.onScreen.contains(bot.id), bot.workspaceName != nil {
                let status = await self.refreshTaskStatus(bot, store: store)
                await self.moveApprovedFiles(bot, store: store)
                try? await Task.sleep(for: status?.busy != nil ? Self.statusWatchBusy : Self.statusWatchIdle)
            }
        }
    }

    func stopWatchingStatus(_ bot: UUID) {
        statusWatches.removeValue(forKey: bot)?.cancel()
    }

    /// Unsent work is sent on its own: GitHub lacks commits of a task in
    /// review or of a backed-up project, nothing holds the copy, you're
    /// signed in. At most once a minute per bot, and never again after
    /// GitHub had commits the work copy lacks (that needs bringing in).
    func resendIfDue(_ bot: Bot, status: DarkmuxClient.GitStatus, store: BotStore) {
        guard (status.ahead ?? 0) > 0, status.busy == nil, githubToken?() != nil, !isPushing(bot.id),
              review(for: bot) != nil || isBackedUp(bot), !remoteMoved.contains(bot.id) else { return }
        if let last = lastResend[bot.id], Date().timeIntervalSince(last) < 60 { return }
        lastResend[bot.id] = Date()
        Task { await self.sendToGitHub(bot, store: store) }
    }

    // MARK: Pushing

    /// How long a push waits for something else holding the work copy (a
    /// run, an Undo, a hand edit) before it says so.
    static let busyWaitLimit: Duration = .seconds(300)

    /// Sends the task's branch to GitHub through darkmux. Nothing is sent
    /// when GitHub has it all already, unless `force` (opening a review). A
    /// project made from a template goes to `repo`, an empty repository, the
    /// first time. While something else holds the work copy it waits; a
    /// sign-in GitHub refused is renewed once and tried again.
    @discardableResult
    func pushTask(_ bot: Bot, store: BotStore, github: String, repo: String? = nil, force: Bool = false) async throws -> DarkmuxClient.GitPushed? {
        guard let workspace = bot.workspaceName else { throw SendRefused(sentence: RunBlocker.noCode.message) }
        try await requireCapability("git_route", skip: gitPusher != nil)
        let status = try await taskStatus(bot)
        if repo == nil, Self.isFromAnEarlierMuxBot(bot, status: status) {
            offerStartFromGitHub(bot, store: store)
            throw SendRefused(sentence: Self.fromAnEarlierMuxBot)
        }
        if !force, repo == nil, (status.ahead ?? status.pending) == 0 { return nil }
        let push = gitPusher ?? { [connection] workspace, github, repo in
            guard let connection, let token = connection.token else { throw NotPaired() }
            return try await connection.client.gitPush(token: token, workspace: workspace, github: github, repo: repo)
        }
        do {
            let pushed = try await whileBusy { try await self.renewingSignIn(github) { try await push(workspace, $0, repo) } }
            remoteMoved.remove(bot.id)
            await refreshTaskStatus(bot)
            return pushed
        } catch let error as DarkmuxClient.ClientError where error.code == "remote_moved" {
            remoteMoved.insert(bot.id)
            throw error
        }
    }

    /// A project an earlier Mux Bot put on GitHub: made from a template,
    /// with a repo, no Put still finishing, and darkmux's status (read just
    /// now) says its work copy has no remote.
    static func isFromAnEarlierMuxBot(_ bot: Bot, status: DarkmuxClient.GitStatus) -> Bool {
        !bot.useCaseId.isEmpty && !bot.repoSlugs.isEmpty && status.origin == nil
            && ModelSettingsStore.shared.pendingRepo(bot: bot.id) == nil
    }

    /// darkmux has `capability`; else one plain sentence (an update, or
    /// darkmux not answering when what it can do can't be read).
    func requireCapability(_ capability: String, skip: Bool = false) async throws {
        guard !skip else { return }
        let known = await capabilities()
        guard darkmuxCapabilities != nil else { throw SendRefused(sentence: Self.darkmuxNotAnswering) }
        if !known.contains(capability) { throw SendRefused(sentence: Self.darkmuxNeedsUpdate) }
    }

    /// `call`, again every few seconds while darkmux says something else
    /// holds the work copy (anything but a run, which can take long; the
    /// caller says that one), up to `busyWaitLimit`.
    func whileBusy<T>(_ call: () async throws -> T) async throws -> T {
        let until = ContinuousClock.now + Self.busyWaitLimit
        while true {
            do {
                return try await call()
            } catch let error as DarkmuxClient.ClientError where Self.waitsFor(error) && ContinuousClock.now < until {
                try await Task.sleep(for: busyRetryInterval)
            }
        }
    }

    /// A refusal that clears on its own soon: the work copy held by a git
    /// step, an Undo, a hand edit or a preview reinstall (never a run).
    nonisolated static func waitsFor(_ error: DarkmuxClient.ClientError) -> Bool {
        guard error.status == 409, let holder = error.holder else { return false }
        return holder.hasPrefix("git:") || ["edit", "undo", "preview_install"].contains(holder)
    }

    /// `call` with your sign-in; GitHub refusing it (`auth_failed`) renews
    /// it once and calls again with the new one.
    func renewingSignIn<T>(_ github: String, _ call: (String) async throws -> T) async throws -> T {
        do {
            return try await call(github)
        } catch let error as DarkmuxClient.ClientError where error.code == "auth_failed" {
            switch await GitHubSession.renewed() {
            case let .token(fresh): return try await call(fresh)
            case .expired: throw SendRefused(sentence: GitHubAuth.expiredMessage)
            case .unreachable: throw error
            }
        }
    }

    // MARK: A project from an earlier Mux Bot

    /// A refusal the thread already said, with its card (never again on
    /// every push).
    static func saidWithItsCard(_ error: any Error) -> Bool {
        (error as? SendRefused)?.sentence == fromAnEarlierMuxBot
    }

    /// The card for a project from an earlier Mux Bot, once per bot this
    /// launch (the sentence comes with it, never again on its own).
    func offerStartFromGitHub(_ bot: Bot, store: BotStore) {
        guard let repo = bot.repoSlugs.first, !offeredStartFromGitHub.contains(bot.id) else { return }
        offeredStartFromGitHub.insert(bot.id)
        store.append(.system, Self.fromAnEarlierMuxBot, to: store.conversation(for: .bot(bot.id)))
        store.proposeAction(.startFromGitHub(repo: repo), in: .bot(bot.id))
    }

    /// A new work copy of the bot's repo from GitHub, checked again first:
    /// nothing going in the old one, and it still has no remote. The old one
    /// stays in darkmux, with whatever it holds that GitHub doesn't.
    func startAgainFromGitHub(_ bot: Bot, store: BotStore) async {
        let thread = store.conversation(for: .bot(bot.id))
        guard connection?.token != nil || workspaceMaker != nil else {
            store.append(.system, RunBlocker.unpaired.message, to: thread)
            return
        }
        if (bot.runs ?? []).contains(where: { $0.phase == .running }) {
            store.append(.system, String(localized: "Wait for the change that's going now to finish, then start again from GitHub."), to: thread)
            return
        }
        if let status = try? await taskStatus(bot), !Self.isFromAnEarlierMuxBot(bot, status: status) {
            store.append(.system, String(localized: "That changed since I asked: this project can be sent to GitHub as it is, so nothing was done."), to: thread)
            return
        }
        let old = bot.workspaceName
        bot.workspaceName = nil
        taskStatuses[bot.id] = nil
        store.save()
        await setUpWorkCopy(for: bot, store: store)
        if case let .failed(why)? = workCopySetup[bot.id] {
            bot.workspaceName = old
            store.save()
            store.append(.system, String(localized: "darkmux couldn't set up a copy from GitHub, so nothing changed: \(why)"), to: thread)
        } else if bot.workspaceName == nil {
            bot.workspaceName = old
            store.save()
            store.append(.system, String(localized: "darkmux couldn't set up a copy from GitHub, so nothing changed."), to: thread)
        } else {
            store.append(.system, String(localized: "Started again from GitHub. The old copy stays on this Mac in darkmux."), to: thread)
        }
    }

    // MARK: Files you approved

    /// The plain name of a file you approved, for the thread.
    nonisolated static func approvedName(_ path: String) -> String {
        switch path {
        case PreviewSetup.path: String(localized: "the preview settings")
        case PlaybookSetup.path: String(localized: "the playbook")
        default: String(localized: "the file you approved")
        }
    }

    /// A file you approved (a preview recipe, a playbook) is saved in the
    /// task's work copy too, as its own change (darkmux #3688), so it goes
    /// to GitHub with the task's other changes and its Undo takes it out.
    /// Returns whether darkmux has it now.
    @discardableResult
    func saveApproved(_ path: String, data: Data, bot: Bot, store: BotStore, quiet: Bool = false) async -> Bool {
        let thread = store.conversation(for: .bot(bot.id))
        let name = Self.approvedName(path)
        guard let workspace = bot.workspaceName else { return false }
        let add = fileAdder ?? { [connection] workspace, path, data in
            guard let connection, let token = connection.token else { throw NotPaired() }
            return try await connection.client.addFile(token: token, workspace: workspace, path: path, data: data)
        }
        do {
            try await requireCapability("workspace_file", skip: fileAdder != nil)
            let saved = try await whileBusy { try await add(workspace, path, data) }
            if saved.workId != nil, !quiet {
                store.append(.system, String(localized: "Saved \(name) with this project's changes, so they go into its next review."), to: thread)
            }
            await sendToGitHub(bot, store: store)
            return true
        } catch {
            if !quiet {
                let said = Self.plain(error)
                let line = store.append(.system, String(localized: "Couldn't save \(name) with this project's changes yet: \(said.sentence) I'll try again."), to: thread)
                messageDetails[line.id] = said.details
            }
            LocalBotState.shared.update(bot.id) { $0.prFiles = ($0.prFiles ?? [:]).merging([path: data]) { $1 } }
            return false
        }
    }

    /// Files approved before (kept by an earlier Mux Bot for its next pull
    /// request), or a save that couldn't happen then: each goes into the
    /// work copy, and is let go only once darkmux has it.
    func moveApprovedFiles(_ bot: Bot, store: BotStore) async {
        guard let files = LocalBotState.shared[bot.id]?.prFiles, !files.isEmpty, bot.workspaceName != nil,
              !movingApproved.contains(bot.id) else { return }
        movingApproved.insert(bot.id)
        defer { movingApproved.remove(bot.id) }
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            LocalBotState.shared.update(bot.id) { $0.prFiles?[path] = nil }
            if !(await saveApproved(path, data: data, bot: bot, store: store, quiet: true)) { return }
        }
    }
}
