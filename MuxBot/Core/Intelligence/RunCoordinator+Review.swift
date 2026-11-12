import Foundation

/// Tasks and review, step one: one automatic task per bot. Start review
/// opens the task's pull request, then the Reviewer checks it once (or you
/// review it yourself); Merge happens here when GitHub says it can, and the
/// next change starts a new task.
extension RunCoordinator {
    /// The current task's open review, if any (this Mac).
    func review(for bot: Bot) -> TaskReview.State? { LocalBotState.shared[bot.id]?.review }

    /// Start review shows where Open PR did: signed in, a work copy and a
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
        do {
            let standing = try await GitHubReview(session: githubSession ?? .shared, token: token).standing(repo: repo, number: state.number)
            reviewStandings[bot.id] = standing
            switch standing {
            case let .merged(sha): await afterMerge(bot, mergeSHA: sha, store: store)
            case .closed:
                LocalBotState.shared.update(bot.id) { $0.review = nil }
                reviewStandings[bot.id] = nil
                store.append(.system, TaskReview.Standing.closed.sentence ?? "", to: store.conversation(for: .bot(bot.id)))
            default: break
            }
        } catch {
            reviewStandings[bot.id] = nil
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
        do {
            let sha = try await GitHubReview(session: githubSession ?? .shared, token: token).merge(repo: repo, number: state.number, title: state.title)
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
    /// next change starts a new task. A project made from a template keeps
    /// its work copy (it already holds everything just merged) and its next
    /// review goes on top of the merge; any other gets a fresh work copy
    /// from the project's main version.
    func afterMerge(_ bot: Bot, mergeSHA: String?, store: BotStore) async {
        guard review(for: bot) != nil else { return }
        let thread = store.conversation(for: .bot(bot.id))
        let fromMain = bot.githubStart == nil
        LocalBotState.shared.update(bot.id) {
            $0.review = nil
            $0.task = ($0.task ?? 1) + 1
            $0.shippedThrough = .now
            $0.pushHead = nil
        }
        reviewStandings[bot.id] = nil
        store.append(.system, TaskReview.nextTaskLine(fromMain: fromMain), to: thread)
        if var start = bot.githubStart {
            start.head = GitHubPR.nextBranch(start.head)
            if let mergeSHA { start.parent = mergeSHA }
            bot.githubStart = start
            return
        }
        // Until the new work copy is made, no run goes to the merged one.
        bot.workspaceName = nil
        store.save()
        await setUpWorkCopy(for: bot, store: store)
    }

    /// A change saved while its task is in review joins the review. A
    /// template project's backup already writes there; any other is pushed
    /// to the review's branch here.
    func updateReview(_ bot: Bot, store: BotStore) async {
        guard review(for: bot) != nil, bot.githubStart == nil, let repo = bot.repoSlugs.first,
              let workspace = bot.workspaceName, let token = githubToken?() else { return }
        await oneAtATime(bot.id) { [self] in
            do {
                let changes = try await changes(for: workspace)
                guard !changes.files.isEmpty else { return }
                let session = githubSession ?? .shared
                let pusher = prPusher ?? { try await GitHubPR(session: session, token: token).push($0, repo: $1, message: $2, bot: $3, start: $4) }
                _ = try await pushMovingOn(bot, changes: changes, store: store) {
                    try await pusher(changes, repo, String(localized: "Update \(bot.name)'s review"), bot.id, $0)
                }
            } catch {
                let said = Self.plain(error)
                let line = store.append(.system, String(localized: "Couldn't add this change to the review on GitHub: \(said.sentence)"),
                                        to: store.conversation(for: .bot(bot.id)))
                messageDetails[line.id] = said.details
            }
        }
    }
}
