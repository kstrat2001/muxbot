import Foundation

/// Tasks and review, step one: one automatic task per bot. Review & merge
/// opens the task's pull request, then the Reviewer checks it once (or you
/// review it yourself); Merge happens here when GitHub says it can, and the
/// next change starts a new task.
extension RunCoordinator {
    /// The current task's open review, if any (this Mac).
    func review(for bot: Bot) -> TaskReview.State? { LocalBotState.shared[bot.id]?.review }

    /// Review & merge can start where Open PR could: signed in, a work copy and a
    /// repo, saved changes not yet in a review, and no review open.
    func canStartReview(_ bot: Bot, store: BotStore, github: GitHubAuth) -> Bool {
        review(for: bot) == nil && canOpenPR(bot, store: store, github: github)
    }

    /// The name darkmux keeps the bot's work copy under. A new task after a
    /// merge asks under a new name, so darkmux makes a fresh work copy from
    /// the project's main version instead of reusing the last task's.
    nonisolated static func workspaceKey(botName: String, task: Int?) -> String {
        guard let task, task > 1 else { return botName }
        let suffix = " \(task)"
        return String(botName.prefix(DarkmuxClient.WorkspaceBody.botNameLimit - suffix.count)) + suffix
    }

    func workspaceKey(_ bot: Bot) -> String {
        Self.workspaceKey(botName: bot.name, task: LocalBotState.shared[bot.id]?.task)
    }

    /// The pull request first, then the review you picked: the Reviewer's
    /// dispatch card (its model shown, one Approve), or none.
    func startReview(for bot: Bot, title: String, byReviewer: Bool, store: BotStore, github: GitHubAuth) async {
        let runs = unshippedRuns(bot, store: store)
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pr = await openPR(for: bot, store: store, github: github, title: clean.isEmpty ? nil : clean) else { return }
        let named = clean.isEmpty ? PRText.make(bot: bot, runs: runs, machine: FleetConnection.machineName).title : clean
        var state = TaskReview.State(number: pr.number, url: pr.url, title: named, mine: !byReviewer)
        if byReviewer {
            let files = Array(Set(runs.flatMap { $0.changedFiles.map { $0.components(separatedBy: " +").first ?? $0 } })).sorted()
            let diff = runs.compactMap(\.diff).joined(separator: "\n")
            let brief = TaskReview.brief(title: named, tasks: runs.map(\.task), files: files,
                                         diff: diff.count <= TaskReview.briefDiffLimit ? diff : nil)
            let run = store.proposeRun(task: String(localized: "Review: \(named)"), crew: .reviewer, on: bot, brief: brief)
            state.reviewerRun = run.id.uuidString
        }
        LocalBotState.shared.update(bot.id) { $0.review = state }
        await refreshReview(bot, store: store, github: github)
    }

    /// The Reviewer finished: its answer becomes the card's list.
    func noteReviewer(_ run: BotRun, report: String) {
        guard run.crew == .reviewer, let bot = run.bot, var state = review(for: bot),
              state.reviewerRun == run.id.uuidString else { return }
        let parsed = TaskReview.parse(report)
        state.items = parsed.items
        state.raw = parsed.raw
        LocalBotState.shared.update(bot.id) { $0.review = state }
    }

    /// "Fix this" (one item) or "Fix these" (the whole answer): a Coder
    /// dispatch card in the same task, so its change joins the review.
    @discardableResult
    func proposeFix(_ text: String, all: Bool, bot: Bot, store: BotStore) -> BotRun {
        store.proposeRun(task: all ? String(localized: "Fix what the review found") : TaskReview.fixTask(text),
                         crew: .coder, on: bot, brief: TaskReview.fixBrief(text, all: all))
    }

    /// Where the review stands on GitHub; a merge made there starts the next
    /// task here too.
    func refreshReview(_ bot: Bot, store: BotStore, github: GitHubAuth) async {
        guard let state = review(for: bot), let repo = bot.repoSlugs.first, let token = github.token else { return }
        await refreshTaskStatus(bot, store: store)
        do {
            let look = try await GitHubReview(session: githubSession ?? .shared, token: token).look(repo: repo, number: state.number)
            let standing = look.standing
            reviewStandings[bot.id] = standing
            reviewHeads[bot.id] = look.head
            switch standing {
            case let .merged(sha): await afterMerge(bot, mergeSHA: sha, store: store)
            case .closed:
                LocalBotState.shared.update(bot.id) { $0.review = nil }
                reviewStandings[bot.id] = nil
                reviewHeads[bot.id] = nil
                store.append(.system, TaskReview.Standing.closed.sentence ?? "", to: store.conversation(for: .bot(bot.id)))
            default: break
            }
        } catch {
            reviewStandings[bot.id] = nil
            reviewHeads[bot.id] = nil
        }
    }

    /// The facts `TaskState` is made of: darkmux's `status` of the work
    /// copy (darkmux #3681) and the review on GitHub, never what one device
    /// remembers. "Busy" is also a run, an Undo, a review being opened, a
    /// push or a Put on GitHub this app has going.
    func taskFacts(_ bot: Bot, store: BotStore) -> TaskState.Facts {
        let runs = bot.runs ?? []
        var facts = TaskState.Facts()
        let status = taskStatuses[bot.id]
        facts.reachable = !taskStatusUnreachable.contains(bot.id)
        facts.busy = status?.busy != nil || runs.contains { $0.phase == .running || deciding.contains($0.id) }
            || openingPR.contains(bot.id) || isPushing(bot.id) || puttingOnGitHub.contains(bot.id)
        facts.head = status?.head
        facts.pending = status?.pending ?? 0
        facts.ahead = status.map { $0.ahead ?? $0.pending } ?? 0
        // Just merged: nothing in this task until its next run starts fresh.
        if LocalBotState.shared[bot.id]?.startFresh == true {
            facts.pending = 0
            facts.ahead = 0
        }
        if review(for: bot) != nil, let standing = reviewStandings[bot.id] {
            let head = reviewHeads[bot.id]
            let reviewStatus: TaskState.Review.Status = switch standing {
            case .merged: .merged
            case .closed: .closed
            default: .open
            }
            facts.review = .init(status: reviewStatus, head: head?.sha ?? "", standing: standing)
        }
        return facts
    }

    func taskState(_ bot: Bot, store: BotStore) -> TaskState {
        TaskState.of(taskFacts(bot, store: store))
    }

    /// Runs `action` when the task allows it now; otherwise says why in the
    /// thread, in one plain sentence, and does nothing.
    @discardableResult
    func whenAllowed(_ action: TaskState.Action, _ bot: Bot, store: BotStore, _ work: () -> Void) -> Bool {
        if let why = taskState(bot, store: store).refusal(action, standing: reviewStandings[bot.id]) {
            store.append(.system, why, to: store.conversation(for: .bot(bot.id)))
            return false
        }
        work()
        return true
    }

    /// Asks GitHub again while it's still working out whether the pull
    /// request can merge (right after it's opened, or after a push), so
    /// Merge shows without a trip to GitHub.
    func followReview(_ bot: Bot, store: BotStore, github: GitHubAuth,
                      sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        await refreshReview(bot, store: store, github: github)
        var tries = 1
        while tries < TaskReview.settleTries, review(for: bot) != nil, reviewStandings[bot.id] == .checking {
            do { try await sleep(TaskReview.settleInterval) } catch { return }
            await refreshReview(bot, store: store, github: github)
            tries += 1
        }
        // Then keep watching while the card is on screen (this task ends
        // with it): a close or merge on GitHub drops Merge here.
        while review(for: bot) != nil {
            do { try await sleep(TaskReview.watchInterval) } catch { return }
            await refreshReview(bot, store: store, github: github)
        }
    }

    /// Merge, in the app. GitHub's refusal is said plainly, and the card
    /// checks again.
    func mergeReview(_ bot: Bot, store: BotStore, github: GitHubAuth) async {
        guard let state = review(for: bot), let repo = bot.repoSlugs.first, let token = github.token,
              !merging.contains(bot.id) else { return }
        merging.insert(bot.id)
        defer { merging.remove(bot.id) }
        let thread = store.conversation(for: .bot(bot.id))
        // Ask GitHub first: a pull request closed or merged there since the
        // card last checked is never merged from here.
        await refreshReview(bot, store: store, github: github)
        guard review(for: bot)?.number == state.number, let standing = reviewStandings[bot.id] else {
            if review(for: bot) != nil {
                store.append(.system, String(localized: "Couldn't reach GitHub to check this review first, so nothing was merged. Try again in a moment."), to: thread)
            }
            return
        }
        // Changes GitHub doesn't have yet are sent first, then the checks
        // look again.
        if taskState(bot, store: store) == .notSent {
            await updateReview(bot, store: store)
            await refreshReview(bot, store: store, github: github)
        }
        // The checks, then the merge at once (no confirmation, Kain
        // 2026-11-16): anything in the way is said, and nothing is merged.
        if let why = taskState(bot, store: store).refusal(.merge, standing: standing) {
            store.append(.system, why, to: thread)
            return
        }
        do {
            let sha = try await GitHubReview(session: githubSession ?? .shared, token: token)
                .merge(repo: repo, number: state.number, title: state.title, sha: taskStatuses[bot.id]?.head ?? reviewHeads[bot.id]?.sha)
            await afterMerge(bot, mergeSHA: sha.isEmpty ? nil : sha, store: store)
        } catch GitHubPR.Failure.cantWrite(let repo) {
            store.append(.system, Self.cantWriteText(repo, await github.installState(for: repo)), to: thread)
        } catch {
            let said = Self.plain(error)
            let line = store.append(.system, String(localized: "Couldn't merge: \(said.sentence)"), to: thread)
            messageDetails[line.id] = said.details
            await refreshReview(bot, store: store, github: github)
        }
    }

    /// The task's changes joined the project: the review closes and the
    /// next change starts a new task from the project's main version. With
    /// darkmux's fresh runs (darkmux #3684) the work copy stays and the next
    /// run starts on a new branch from the merged main, fetched now;
    /// without, a fresh work copy is made.
    func afterMerge(_ bot: Bot, mergeSHA: String?, store: BotStore) async {
        guard review(for: bot) != nil else { return }
        let thread = store.conversation(for: .bot(bot.id))
        let canStartFresh = gitFetcher != nil ? true : (await capabilities()).contains("fresh_branch")
        let fresh = bot.workspaceName != nil && canStartFresh
        LocalBotState.shared.update(bot.id) {
            $0.review = nil
            $0.shippedThrough = .now
            if fresh { $0.startFresh = true } else { $0.task = ($0.task ?? 1) + 1 }
        }
        reviewStandings[bot.id] = nil
        reviewHeads[bot.id] = nil
        store.append(.system, TaskReview.nextTaskLine(fromMain: true), to: thread)
        if fresh {
            if let token = githubToken?() { _ = try? await fetchTask(bot, github: token) }
            return
        }
        // Until the new work copy is made, no run goes to the merged one.
        bot.workspaceName = nil
        taskStatuses[bot.id] = nil
        store.save()
        await setUpWorkCopy(for: bot, store: store)
    }

    /// Fetches the project's branches into the work copy (darkmux #3681).
    @discardableResult
    func fetchTask(_ bot: Bot, github: String?) async throws -> DarkmuxClient.GitStatus {
        guard let workspace = bot.workspaceName else { throw SendRefused(sentence: RunBlocker.noCode.message) }
        let fetch = gitFetcher ?? { [connection] workspace, github in
            guard let connection, let token = connection.token else { throw NotPaired() }
            return try await connection.client.gitFetch(token: token, workspace: workspace, github: github)
        }
        let status = try await fetch(workspace, github)
        taskStatuses[bot.id] = status
        return status
    }

    /// Bring in changes: the project's main version moved in a way that
    /// blocks the merge, so darkmux fetches it, brings it into the task
    /// (`merge_main`), and the task goes to its review again. A conflict
    /// changes nothing and says so.
    func bringInChanges(_ bot: Bot, store: BotStore, github: GitHubAuth) async {
        let thread = store.conversation(for: .bot(bot.id))
        let state = taskState(bot, store: store)
        if let why = state.refusal(.bringInChanges, standing: reviewStandings[bot.id]) {
            store.append(.system, why, to: thread)
            return
        }
        guard state == .mainMoved else {
            store.append(.system, String(localized: "Someone changed this review on GitHub. Mux Bot can't bring those changes in from here yet: look at them with See it on GitHub."), to: thread)
            return
        }
        guard let token = github.token, let workspace = bot.workspaceName else { return }
        await oneAtATime(bot.id) { [self] in
            do {
                try await fetchTask(bot, github: token)
                let merge = gitMerger ?? { [connection] workspace in
                    guard let connection, let token = connection.token else { throw NotPaired() }
                    return try await connection.client.gitMergeMain(token: token, workspace: workspace)
                }
                let merged = try await merge(workspace)
                if !merged.upToDate {
                    _ = try await pushTask(bot, store: store, github: token)
                    store.append(.system, String(localized: "Brought in the project's latest version. The review has it now."), to: thread)
                }
            } catch {
                let said = Self.plain(error)
                let line = store.append(.system, String(localized: "Couldn't bring in the latest version: \(said.sentence)"), to: thread)
                messageDetails[line.id] = said.details
            }
        }
        await refreshReview(bot, store: store, github: github)
    }

    /// A change saved while its task is in review joins the review: the
    /// task's branch goes to GitHub again through darkmux.
    func updateReview(_ bot: Bot, store: BotStore) async {
        guard review(for: bot) != nil, bot.workspaceName != nil, ModelSettingsStore.shared.pendingRepo(bot: bot.id) == nil,
              let token = githubToken?() else { return }
        await oneAtATime(bot.id) { [self] in
            do {
                _ = try await pushTask(bot, store: store, github: token)
            } catch {
                if Self.saidWithItsCard(error) { return }
                let said = Self.plain(error)
                let line = store.append(.system, String(localized: "Couldn't add this change to the review on GitHub: \(said.sentence)"),
                                        to: store.conversation(for: .bot(bot.id)))
                messageDetails[line.id] = said.details
            }
        }
    }
}
