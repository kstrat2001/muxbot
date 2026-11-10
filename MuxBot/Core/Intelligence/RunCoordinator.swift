import Foundation
import OSLog
import SwiftData

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The run loop: approving, sending work to darkmux, following it to a
/// result, Keep / Tweak / Discard / Stop, plus each bot's work copy and live
/// preview on this Mac. Bots propose; this carries out what you approve.
@MainActor @Observable
final class RunCoordinator {
    /// The pairing with darkmux on this Mac; when paired, approved runs go to darkmux.
    var connection: FleetConnection? {
        didSet {
            // Pairing completes inside the connection (no new connection), so
            // it says so here too.
            connection?.onPaired = { [weak self] in self?.connectionAttached() }
            if connection != nil { connectionAttached() }
        }
    }
    /// Posts "result ready" / "didn't finish" notifications.
    var notifier: NotificationService?
    var recipes = RecipeStore()
    var github: any GitHubClient = RESTGitHubClient()
    /// Off in tests: summaries use the plain template.
    var useOnDeviceModel = true
    /// Whether this device can start runs (the Mac app; tests set it).
    var deviceRuns = RunBlocker.deviceRuns

    /// The run a Tweak is aimed at; the next message in its bot's thread
    /// goes to that run instead of starting a new conversation turn.
    var tweakRunId: UUID?

    /// A person's decision on a run card: Approve, Cancel, Keep, Discard,
    /// Open PR, Not now. Approve starts the run on darkmux.
    func decide(_ event: RunEvent, on run: BotRun, store: BotStore) {
        // Nothing fake ever runs: a run that can't go to darkmux isn't started.
        if event == .approve, let reason = whyRunCannotStart(run) {
            if let bot = run.bot { store.append(.system, "Can't run this yet: \(reason).", to: store.conversation(for: .bot(bot.id))) }
            return
        }
        // Close: a result with nothing to undo (a question, or changes
        // darkmux couldn't commit) is done, here only.
        if event == .close {
            decisionErrors[run.id] = nil
            store.apply(.close, to: run)
            return
        }
        // No commit, nothing to revert: Undo would ask darkmux to undo a
        // commit that doesn't exist.
        if event == .discard, run.phase == .result, !run.changedFiles.isEmpty, run.keptCommit == nil {
            decisionErrors[run.id] = "There's no commit to undo: \(RunCardState.checkpointProblem(run) ?? "darkmux didn't commit these changes.")"
            return
        }
        // A run that changed nothing: there's nothing to keep, and closing it
        // needs no darkmux (there's nothing to undo).
        if event == .keep || event == .discard, run.phase == .result, run.changedFiles.isEmpty {
            if event == .keep {
                decisionErrors[run.id] = "Nothing changed, so there's nothing to keep."
            } else {
                decisionErrors[run.id] = nil
                store.apply(.discard, to: run)
            }
            return
        }
        // A finished run with changes is already committed: nothing to keep.
        if event == .keep, run.phase == .result { return }
        // Undo acts on the files first; the card moves only when darkmux has
        // done it, and says what it did.
        if event == .discard, run.darkmuxWorkId != nil {
            Task { await applyOnDisk(event, to: run, store: store) }
            return
        }
        // A card this Mac didn't just propose (after a relaunch, synced from
        // another device, or Approve before the listing came back) has no
        // model choice yet: it's chosen first, and Always ask or a default
        // model that isn't here is shown on the card, never skipped. The
        // next Approve, with the picker or the warning on screen, goes.
        if event == .approve, run.phase == .proposed, runChoices[run.id] == nil {
            guard choosingModel[run.id] == nil else { return }
            choosingModel[run.id] = Task { @MainActor [self] in
                await chooseProfile(for: run)
                choosingModel[run.id] = nil
                guard let choice = runChoices[run.id], !choice.ask, choice.unavailable == nil else { return }
                decide(.approve, on: run, store: store)
            }
            return
        }
        guard store.apply(event, to: run) else { return }
        if event == .approve { _ = startRealRun(run, message: run.brief ?? run.task, store: store) }
    }

    /// Runs with Keep or Discard in flight (their buttons wait).
    var deciding: Set<UUID> = []
    /// Why the last Undo didn't happen, shown on the card.
    var decisionErrors: [UUID: String] = [:]

    /// Undo (the card's one button): darkmux reverts the run's commit.
    /// Keep is never needed (darkmux committed the run when it finished).
    private func applyOnDisk(_ event: RunEvent, to run: BotRun, store: BotStore) async {
        guard event == .discard else { return }
        guard run.startedHere else {
            decisionErrors[run.id] = String(localized: "Undo it from the Mac it ran on.")
            return
        }
        guard run.phase == .result, !deciding.contains(run.id), let bot = run.bot,
              run.darkmuxWorkId != nil, let connection, let token = connection.token else {
            if connection?.token == nil { decisionErrors[run.id] = "Can't do that yet: \(RunBlocker.unpaired.message)." }
            return
        }
        let thread = store.conversation(for: .bot(bot.id))
        deciding.insert(run.id)
        defer { deciding.remove(run.id) }
        // Every turn of the run (the run and each Tweak is its own darkmux
        // commit), newest first.
        var pending = Array(workIds(for: run).reversed())
        var restored: [String] = []
        do {
            while let workId = pending.first {
                let undone: DarkmuxClient.UndoResult
                if let workUndoer { undone = try await workUndoer(workId) } else { undone = try await connection.client.undoWork(token: token, workId: workId) }
                restored += undone.files.filter { !restored.contains($0) }
                pending.removeFirst()
                forgetWork(workId, for: run)
            }
            store.append(.system, RunResultText.discarded(restored: restored, removed: []).replacingOccurrences(of: "Put back", with: "Undone: put back"), to: thread)
            decisionErrors[run.id] = nil
            Task { await self.refreshPreview(for: bot) }
            if run.phase == .result {
                store.apply(.discard, to: run)
            } else {
                // The run moved on while darkmux undid it: say so, never drop
                // the discard silently.
                store.append(.system, "The undo and your reply overlapped: darkmux undid “\(run.task)”, and the run went on from there. Check its changes before you continue.", to: thread)
            }
        } catch let error as DarkmuxClient.ClientError where error.status == 404 {
            // darkmux restarted and no longer tracks the run; its commit is
            // still in the work copy's history.
            let commit = run.keptCommit.map { " Its commit is \($0)\(run.keptBranch.map { " on \($0)" } ?? "")." } ?? ""
            decisionErrors[run.id] = Self.partly(restored) + "darkmux no longer tracks this run, so it can't undo it from here.\(commit)"
        } catch let error as DarkmuxClient.ClientError {
            decisionErrors[run.id] = Self.partly(restored) + RunResultText.undoRefusal(error.message, runs: bot.runs ?? [])
            decisionDetails[run.id] = DarkmuxPlain.details(error)
        } catch {
            decisionErrors[run.id] = Self.partly(restored) + String(localized: "Couldn't undo it: \(DarkmuxPlain.sentence(error))")
            decisionDetails[run.id] = DarkmuxPlain.details(error)
        }
    }

    /// An Undo that got partway (the latest Tweak undone, an earlier turn
    /// refused): said first, and the run stays a result.
    nonisolated static func partly(_ restored: [String]) -> String {
        restored.isEmpty ? "" : String(localized: "The latest change was undone, but not the earlier one. ")
    }

    /// Every darkmux run gets the same working rules after its task, plus
    /// the repo's own hints from its `.darkmux/preview.json`, never a guess
    /// about how some other kind of project is laid out.
    nonisolated static func workBrief(_ task: String, recipe: PreviewManifest? = nil, skills: [BotSkill] = []) -> String {
        let hints = recipe?.conventions.map { "\n\nAbout this repository: \($0)" } ?? ""
        let howTo = skills.map { "\n\nHow this kind of change is done here (\($0.name)):\n\($0.body)" }.joined()
        return task + hints + howTo + """


            You are working in this repository (the current directory). Find the file responsible, \
            make the smallest change that does it, and change nothing else. Don't run installs, builds \
            or the dev server. If you can't find where to change, stop and say what you searched instead \
            of repeating searches. When done, list the files you changed.
            """
    }

    /// darkmux refusing or not answering a submit fails the run; it is never
    /// a result to Keep.
    nonisolated static func startFailure(_ error: any Error) -> RunEvent {
        .fail(reason: "Couldn't start on darkmux", details: DarkmuxPlain.details(error))
    }

    /// A Tweak re-sends the original brief, what the run changed, and the
    /// change you asked for, so the crew has the whole picture.
    static func tweakMessage(for run: BotRun, change: String) -> String {
        var parts = ["Earlier task:\n\(run.brief ?? run.task)"]
        if !run.changedFiles.isEmpty {
            parts.append("You already changed: \(run.changedFiles.joined(separator: ", ")).")
        }
        parts.append("Now change this: \(change)")
        return parts.joined(separator: "\n\n")
    }

    /// Polls a darkmux run until it ends, then posts its result (or notes
    /// that it was stopped).
    /// Runs whose darkmux can't be reached right now (the card says so).
    var unreachableRuns: Set<UUID> = []

    private func follow(_ run: BotRun, workId: String, store: BotStore) async {
        var backoff = PollBackoff()
        // One follower per run, however often following resumes.
        guard following.insert(run.id).inserted else { return }
        defer {
            unreachableRuns.remove(run.id)
            following.remove(run.id)
            slotFreed(store: store)
        }
        while run.phase == .running, run.darkmuxWorkId == workId {
            try? await Task.sleep(for: .seconds(pollInterval ?? backoff.delay))
            let status: DarkmuxClient.WorkStatus
            do {
                if let workStatusFetcher {
                    status = try await workStatusFetcher(workId)
                } else {
                    // The current token each time: a revoked pairing (401)
                    // clears it, and following waits until you pair again.
                    guard let connection, let token = connection.token else { continue }
                    status = try await connection.client.workStatus(token: token, workId: workId)
                }
                backoff.succeeded()
                unreachableRuns.remove(run.id)
            } catch let error as DarkmuxClient.ClientError where error.status == 404 {
                // darkmux no longer knows this run (restarted, or it ended long
                // ago). Nobody stopped it: say what happened.
                if tweakBase(run) != nil {
                    restoreTweak(run, store: store, saying: RunResultText.lostTrack + " " + String(localized: "The result before the change is unchanged."))
                } else {
                    store.apply(.fail(reason: RunResultText.lostTrack, details: nil), to: run)
                }
                return
            } catch {
                // darkmux unreachable: back off, say so after three misses, keep trying.
                backoff.failed()
                if backoff.isUnreachable { unreachableRuns.insert(run.id) }
                continue
            }
            switch status.status {
            case "running", "cancelling": continue
            case "cancelled":
                if tweakBase(run) != nil {
                    restoreTweak(run, store: store, saying: String(localized: "The change was stopped. The result before it is unchanged."))
                } else {
                    store.apply(.stop, to: run)
                }
                return
            case "done":
                await finishRun(run, status: status, store: store)
                return
            default:
                // An error is a failure, worded from darkmux's code; only
                // "cancelled" (above) is a stop.
                let why = RunResultText.failure(code: status.code, error: status.error ?? "", reason: status.reason)
                if tweakBase(run) != nil {
                    restoreTweak(run, store: store, saying: String(localized: "The change didn't finish: \(why) The result before it is unchanged."))
                    return
                }
                store.apply(.fail(reason: "Didn't finish: \(why)", details: RunResultText.withoutPlumbing(status.error ?? "")), to: run)
                if let notice = RunNotice.make(for: run) { await notifier?.post(notice, runId: run.id) }
                return
            }
        }
    }

    /// A darkmux run that finished: its report, changes and commit go on the
    /// run, and it becomes the bot's result.
    func finishRun(_ run: BotRun, status: DarkmuxClient.WorkStatus, store: BotStore) async {
        let report = status.finalAssistant ?? ""
        run.notes = report.isEmpty ? nil : report
        // A Tweak's files join the run's (each turn is its own commit, and
        // Undo reverts them all); a file changed again shows its latest line.
        let now = (status.changes?.files ?? []).map { f in "\(f.path) +\(f.added ?? 0) −\(f.removed ?? 0)" }
        let path: (String) -> String = { line in line.components(separatedBy: " +").first ?? line }
        let newPaths = Set(now.map(path))
        run.changedFiles = run.changedFiles.filter { !newPaths.contains(path($0)) } + now
        if let diff = status.changes?.diff { run.diff = diff }
        setTweakBase(run, nil)
        // darkmux committed the changes to the work copy's branch. A tweak
        // that ended with nothing new to commit keeps the commit it was built
        // on (Open PR needs it); a commit error replaces any older one.
        if let commit = status.commit {
            run.keptCommit = commit
            run.keptBranch = status.branch
        }
        run.details = status.commitError
        // darkmux couldn't read what changed: never "changed nothing".
        if status.changes == nil, let why = status.changesError {
            run.details = [RunResultText.changesUnreadable + ": " + why, run.details].compactMap { $0 }.joined(separator: "\n")
        }
        let summary = await summarize(report: report, files: (status.changes?.files ?? []).map(\.path), botName: run.bot?.name)
        store.apply(.finish(summary: summary), to: run)
        // Show the change in the preview you have open.
        if !run.changedFiles.isEmpty, let bot = run.bot { Task { await self.refreshPreview(for: bot) } }
        if !run.changedFiles.isEmpty, checkSpecs[run.id] != nil {
            // Give the preview's hot reload a moment, then check.
            Task { try? await Task.sleep(for: .seconds(2)); await self.check(run) }
        }
        // The notice can wait on macOS's "allow notifications?" prompt, so it
        // runs on its own and nothing after it waits for it.
        if let notice = RunNotice.make(for: run) {
            let post = noticePoster ?? { [notifier] in await notifier?.post($0, runId: $1) }
            let runId = run.id
            Task { await post(notice, runId) }
        }
        // A project the app made on GitHub: its committed work is backed up
        // to the bot's branch there (no PR until you open one).
        if status.commit != nil, let bot = run.bot, bot.githubStart != nil { await backUp(bot, store: store) }
    }

    /// A use case's template, from the registry (or the test seam).
    func template(for id: String) async -> TemplateEntry? {
        await (templateSource ?? Self.registryTemplate)(id)
    }

    struct NotPaired: LocalizedError {
        var errorDescription: String? { RunBlocker.unpaired.message }
    }

    /// darkmux's changes on a workspace's branch against its base.
    func changes(for workspace: String) async throws -> DarkmuxClient.Changes {
        if let changesFetcher { return try await changesFetcher(workspace) }
        guard let connection, let darkmux = connection.token else { throw NotPaired() }
        return try await connection.client.changes(token: darkmux, workspace: workspace)
    }

    /// Pushes a GitHub-started project's committed work to its `mux/<bot>`
    /// branch on your repo, through the same path as Open PR. Says so only
    /// when it fails.
    /// Pushes waiting behind this bot's GitHub push, which runs one at a
    /// time so a backup and an Open PR never race for the same branch.
    @ObservationIgnored private var pushTails: [UUID: Task<Void, Never>] = [:]
    /// Bots being put on GitHub (`PutOnGitHub`): kept here, not in the view,
    /// so closing bot info never lets a second Put start.
    var puttingOnGitHub: Set<UUID> = []
    /// Bots told their work isn't backed up because you're signed out.
    private var saidNotBackedUp: Set<UUID> = []
    /// Names tried after a branch someone else pushed to.
    static let branchTries = 5

    /// Runs `work` after every earlier GitHub push for `bot` has finished.
    func oneAtATime(_ bot: UUID, _ work: @escaping @MainActor () async -> Void) async {
        let before = pushTails[bot]
        let mine = Task { @MainActor in
            await before?.value
            await work()
        }
        pushTails[bot] = mine
        await mine.value
        if pushTails[bot] == mine { pushTails[bot] = nil }
    }

    /// Where this Mac pushes the bot's work on GitHub: its GitHub start, or
    /// the branch it moved to after someone else pushed to darkmux's.
    func pushStart(_ bot: Bot, changes: DarkmuxClient.Changes) -> GitHubPR.Start? {
        if let start = bot.githubStart { return start }
        guard bot.useCaseId.isEmpty else { return nil }
        return LocalBotState.shared[bot.id]?.pushHead.map { GitHubPR.Start(commit: changes.base, branch: changes.baseBranch, head: $0) }
    }

    /// Pushes through `push`. When someone else pushed to the bot's branch,
    /// it's never overwritten: the work goes to the next free name
    /// (`mux/<bot>-2`) from then on, and the thread says so.
    func pushMovingOn<T>(_ bot: Bot, changes: DarkmuxClient.Changes, store: BotStore,
                         _ push: (GitHubPR.Start?) async throws -> T) async throws -> T {
        var start = pushStart(bot, changes: changes)
        for _ in 0..<Self.branchTries {
            do {
                return try await push(start)
            } catch GitHubPR.Failure.branchMoved(let moved) {
                let next = GitHubPR.nextBranch(moved)
                if var kept = bot.githubStart {
                    kept.head = next
                    bot.githubStart = kept
                    start = kept
                } else {
                    LocalBotState.shared.update(bot.id) { $0.pushHead = next }
                    start = GitHubPR.Start(commit: changes.base, branch: changes.baseBranch, head: next)
                }
                store.append(.system, String(localized: "Someone else pushed to \(moved) on GitHub, so I left it as it is. This bot's work goes to \(next) from now on."),
                             to: store.conversation(for: .bot(bot.id)))
            }
        }
        throw GitHubPR.Failure.branchMoved(start?.head ?? changes.branch)
    }

    func backUp(_ bot: Bot, store: BotStore) async {
        if bot.githubStart == nil { await recoverStart(bot) }
        guard bot.githubStart != nil, let repo = bot.repoSlugs.first, let workspace = bot.workspaceName,
              LocalBotState.shared[bot.id]?.putPending != true,
              changesFetcher != nil || connection?.token != nil else { return }
        guard let token = githubToken?() else {
            // Said once per bot, until a backup goes through again.
            if !saidNotBackedUp.contains(bot.id), let head = bot.githubStart?.head {
                saidNotBackedUp.insert(bot.id)
                store.append(.system, String(localized: "Not backed up: sign in with GitHub (Settings › GitHub) to back up to \(head)."),
                             to: store.conversation(for: .bot(bot.id)))
            }
            return
        }
        saidNotBackedUp.remove(bot.id)
        await oneAtATime(bot.id) { [self] in
            do {
                let changes = try await changes(for: workspace)
                guard !changes.files.isEmpty else { return }
                let session = githubSession ?? .shared
                let pusher = prPusher ?? { try await GitHubPR(session: session, token: token).push($0, repo: $1, message: $2, bot: $3, start: $4) }
                _ = try await pushMovingOn(bot, changes: changes, store: store) {
                    try await pusher(changes, repo, String(localized: "Back up \(bot.name)'s work"), bot.id, $0)
                }
            } catch {
                let said = Self.plain(error)
                let line = store.append(.system, String(localized: "Couldn't back up this work to \(bot.githubStart?.head ?? "its branch") on GitHub: \(said.sentence)"),
                                        to: store.conversation(for: .bot(bot.id)))
                messageDetails[line.id] = said.details
            }
        }
    }

    /// Only a run that changed files gets the model's summary: asked "what
    /// you changed" with none, it invents an edit (Fix #10, 2026-11-07).
    nonisolated static func modelSummarizes(report: String, files: [String]) -> Bool {
        !report.isEmpty && !files.isEmpty
    }

    /// One or two friendly sentences in the bot's own voice about what was
    /// wrong and what changed: the on-device model when it can, else a
    /// plain template.
    private func summarize(report: String, files: [String], botName: String?) async -> String {
        let fallback = RunResultText.fallbackSummary(report: report, files: files)
        #if canImport(FoundationModels)
        guard useOnDeviceModel, BotBrain.modelUnavailableReason == nil, Self.modelSummarizes(report: report, files: files) else { return fallback }
        let session = LanguageModelSession(instructions: """
            You are \(botName ?? "a bot") in Mux Bot. In one or two short, friendly sentences, in the first person, \
            plain text with no markdown, say what was wrong and what you changed. Mention the file by name.
            """)
        let prompt = "Report:\n\(String(RunResultText.plain(report).prefix(1500)))\nFiles changed: \(files.joined(separator: ", "))"
        guard let line = try? await session.respond(to: prompt).content.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty, line.count < 400, !line.contains("**") else { return fallback }
        return line
        #else
        return fallback
        #endif
    }

    /// The app can't open pull requests yet (no GitHub sign-in): pass the
    /// request to the lead bot's thread, honestly, and close the card.
    func passPRToLead(_ run: BotRun, store: BotStore) {
        guard let bot = run.bot else { return }
        let workCopy = bot.workspaceName.map { " Work copy: darkmux workspace \($0) on \(bot.workspaceMachine ?? "this Mac")." } ?? ""
        store.append(.system, "From \(bot.name): open a pull request for “\(run.task)”.\(workCopy)", to: store.conversation(for: .lead))
        store.append(.system, "Passed to \(LeadBot.name).", to: store.conversation(for: .bot(bot.id)))
        store.apply(.skipPR, to: run)
    }

    /// After a relaunch, pick up runs that were still going on darkmux.
    func resumeFollowing(store: BotStore) {
        guard workStatusFetcher != nil || connection?.token != nil else { return }
        let runs = (try? store.context.fetch(FetchDescriptor<BotRun>())) ?? []
        // Earlier builds stored a raw darkmux error as the result; show those as
        // a plain outcome now.
        for run in runs where run.phase == .result {
            guard run.summary.hasPrefix("darkmux reported an error") else { continue }
            let raw = String(run.summary.dropFirst("darkmux reported an error: ".count))
            run.details = RunResultText.withoutPlumbing(raw)
            switch RunResultText.classify(error: raw, reason: nil) {
            case .stopped: run.phase = .canceled
            case let .failed(why): run.phase = .failed; run.summary = "Didn't finish: \(why)"
            }
            if let bot = run.bot { store.refreshState(of: bot) }
        }
        // Only runs this device started: another Mac's runs sync here too,
        // and this Mac's darkmux never had them.
        for run in runs where run.phase == .running && run.startedHere {
            guard let workId = run.darkmuxWorkId else {
                guard !starting.contains(run.id) else { continue }
                // A Tweak darkmux never had: back to the result it continued.
                if tweakBase(run) != nil {
                    restoreTweak(run, store: store, saying: Self.tweakQuitBeforeStart)
                } else {
                    // Approved, but the app quit before darkmux had it.
                    store.apply(.fail(reason: RunResultText.quitBeforeStart, details: nil), to: run)
                }
                continue
            }
            Task { await follow(run, workId: workId, store: store) }
        }
    }

    /// Stops a running run: darkmux cancels it (TERM, then KILL, and its
    /// container); the card shows it stopped.
    func stop(_ run: BotRun, store: BotStore) async {
        guard run.phase == .running else { return }
        let say: (String) -> Void = { text in
            if let bot = run.bot { store.append(.system, text, to: store.conversation(for: .bot(bot.id))) }
        }
        // It's stopped only once darkmux accepts the cancel: never marked
        // stopped while it keeps running somewhere.
        guard run.startedHere else { say(Self.stopElsewhere); return }
        if let workId = run.darkmuxWorkId {
            do {
                if let workCanceller {
                    try await workCanceller(workId)
                } else if let connection, let token = connection.token {
                    try await connection.client.cancelWork(token: token, workId: workId)
                } else {
                    say(Self.stopUnpaired)
                    return
                }
            } catch {
                say(Self.stopFailure(error))
                return
            }
        }
        // Not on darkmux yet (waiting for a slot, or being handed over):
        // nothing to cancel there, and it never starts later.
        if run.darkmuxWorkId == nil { queued.removeAll { $0.run.id == run.id } }
        // A Tweak stops back to the result it continued.
        if tweakBase(run) != nil {
            restoreTweak(run, store: store, saying: String(localized: "Stopped the change. The result before it is unchanged."))
            return
        }
        // No work id: still being handed to darkmux (the submit sees the stop
        // and cancels it there), or it never got there.
        store.apply(.stop, to: run)
    }

    /// What stops a run going to darkmux right now, or nil when it can.
    func blocker(for run: BotRun) -> RunBlocker? {
        guard let bot = run.bot else { return .noCode }
        return RunBlocker.check(paired: connection?.isPaired == true && connection?.token != nil, crew: run.crew, bot: bot,
                                deviceRuns: deviceRuns, excluding: run.id)
    }

    /// Why a run can't go to darkmux right now, or nil when it can.
    func whyRunCannotStart(_ run: BotRun) -> String? {
        blocker(for: run)?.message
    }

    // MARK: Live previews

    /// darkmux-run previews, by bot.
    var livePreviews: [UUID: LivePreview] = [:]
    /// Tests answer a clean start (Start over) here.
    var previewCleanStarter: (() async throws -> LivePreview)?
    /// Tests answer whether darkmux can start over here.
    var startOverProbe: (() async -> Bool)?
    /// darkmux can start a preview over (`{"clean": true}`), as asked once
    /// (again after a preview fails, in case darkmux changed meanwhile).
    private(set) var canStartOver = false
    private var startOverChecked = false

    func checkStartOver() async {
        guard !startOverChecked else { return }
        if let startOverProbe {
            startOverChecked = true
            canStartOver = await startOverProbe()
            return
        }
        guard let connection, let token = connection.token else { return }
        startOverChecked = true
        canStartOver = await connection.client.supportsCleanStart(token: token)
    }

    /// Start over: darkmux reinstalls the project's packages and starts the
    /// preview again, running or not. Nothing at all where darkmux can't,
    /// never a plain restart in its place.
    func startOver(for bot: Bot) async {
        guard canStartOver, bot.workspaceName != nil else { return }
        let before = livePreviews[bot.id]?.url
        livePreviews[bot.id] = nil
        await ensurePreview(for: bot, clean: true)
        // Same address: the page is reloaded so it shows the new server.
        if let now = livePreviews[bot.id], now.status == .ready, now.url == before {
            previewReloads[bot.id, default: 0] += 1
        }
    }

    /// Counts up each time a bot's open preview should reload (after a run
    /// changed files, or Undo); the panel reloads its page on a change.
    var previewReloads: [UUID: Int] = [:]

    /// After a run changed files (or Undo put them back): the preview this
    /// app opened shows the result. darkmux is asked its status first, so a
    /// preview that stopped meanwhile is never left on screen as a stale
    /// page: a live one is reloaded, a stopped one restarted (the panel
    /// shows its status card meanwhile). A preview nobody opened isn't
    /// started.
    func refreshPreview(for bot: Bot) async {
        guard let name = bot.workspaceName, previewWorkspaces[bot.id] != nil,
              let status = livePreviews[bot.id]?.status, status == .ready else { return }
        let now: LivePreview?
        if let previewFetcher {
            now = try? await previewFetcher(false)
        } else if let connection, let token = connection.token {
            now = try? await connection.client.previewStatus(token: token, workspace: name).live
        } else {
            now = nil
        }
        // Left the thread meanwhile: nothing to show.
        guard livePreviews[bot.id]?.status == .ready else { return }
        if let now, now.status == .ready {
            livePreviews[bot.id] = now
            previewReloads[bot.id, default: 0] += 1
            return
        }
        Self.previewLog.info("preview \(name, privacy: .public): not running after the run, starting it again")
        livePreviews[bot.id] = now ?? LivePreview(status: .stopped)
        await ensurePreview(for: bot)
    }

    /// The URL the preview panel shows for a bot.
    func previewURL(for bot: Bot) -> URL? {
        LivePreview.url(darkmux: livePreviews[bot.id], resource: bot.previewURL)
    }

    /// Whether a preview can be shown: darkmux can run one in the bot's work
    /// copy, or you added a preview link.
    func canPreview(_ bot: Bot) -> Bool {
        (bot.workspaceName != nil && connection?.isPaired == true) || bot.previewURL != nil
    }

    /// Has darkmux run the bot's preview, and follows it until it's ready or
    /// fails. Does nothing without a work copy or pairing (a preview link
    /// is shown as is).
    func ensurePreview(for bot: Bot, clean: Bool = false) async {
        guard let name = bot.workspaceName else {
            Self.previewLog.debug("preview \(bot.name, privacy: .public): no work copy, nothing to start")
            return
        }
        if let connection, connection.token == nil {
            // Not paired (or darkmux forgot this app): say so, with Pair, and
            // start it once you have (connectionAttached).
            livePreviews[bot.id] = LivePreview(status: .unavailable(.notPaired))
            waitingPreviews[bot.id] = bot
            return
        }
        guard let connection, let token = connection.token else {
            // At launch the connection attaches a moment later: say so, and
            // start once it's here (connectionAttached).
            Self.previewLog.info("preview \(name, privacy: .public): waiting, darkmux \(self.connection == nil ? "not attached" : "not paired", privacy: .public)")
            waitingPreviews[bot.id] = bot
            livePreviews[bot.id] = LivePreview(status: .waiting)
            return
        }
        waitingPreviews[bot.id] = nil
        previewWorkspaces[bot.id] = name
        // Opening it again calls off a stop waiting out its grace period.
        returnToPreview(for: bot)
        if let status = livePreviews[bot.id]?.status, !status.canRetry {
            // A cached "ready" may be stale (idle-stopped, darkmux restarted):
            // ask darkmux before trusting it, and start it again if it's gone.
            guard status == .ready, !clean else {
                Self.previewLog.debug("preview \(name, privacy: .public): already \(String(describing: status), privacy: .public)")
                return
            }
            do {
                let now: LivePreview
                if let previewFetcher { now = try await previewFetcher(false) } else { now = try await connection.client.previewStatus(token: token, workspace: name).live }
                if now.status == .ready {
                    livePreviews[bot.id] = now
                    runPendingChecks(for: bot)
                    return
                }
            } catch let error as URLError where Self.isNotAnswering(error) {
                livePreviews[bot.id] = LivePreview(status: .unavailable(.notAnswering))
                return
            } catch {
                // 404 (darkmux no longer has it) or anything else: start it again.
            }
        }
        Self.previewLog.info("preview \(name, privacy: .public): asking darkmux to start it")
        livePreviews[bot.id] = LivePreview(status: .starting)
        let fetcher = previewFetcher, cleanStarter = previewCleanStarter
        let fetch: (Bool) async throws -> LivePreview = { start in
            if start, clean {
                if let cleanStarter { return try await cleanStarter() }
                return try await connection.client.startPreview(token: token, workspace: name, clean: true).live
            }
            if let fetcher { return try await fetcher(start) }
            return start ? try await connection.client.startPreview(token: token, workspace: name).live
                         : try await connection.client.previewStatus(token: token, workspace: name).live
        }
        do {
            var p = try await fetch(true)
            livePreviews[bot.id] = p
            let deadline = Date().addingTimeInterval(previewDeadline)
            var misses = 0
            while [.starting, .installing].contains(p.status), Date() < deadline {
                try await Task.sleep(for: .seconds(min(1, previewDeadline / 4)))
                do {
                    p = try await fetch(false)
                    misses = 0
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One failed status call isn't a failed preview: back off
                    // and ask again; only three in a row count.
                    misses += 1
                    if misses >= 3 { throw error }
                    continue
                }
                livePreviews[bot.id] = p
            }
            if [.starting, .installing].contains(p.status) {
                // Out of time: failed, so opening the preview again retries.
                livePreviews[bot.id] = LivePreview(status: .failed(String(localized: "it didn't start within \(Int(previewDeadline / 60)) minutes")))
            }
            Self.previewLog.info("preview \(name, privacy: .public): \(String(describing: p.status), privacy: .public)")
            if p.status == .ready { runPendingChecks(for: bot) }
        } catch is CancellationError {
            // Left the thread while it started: not a failure; it starts again next time.
            livePreviews[bot.id] = LivePreview(status: .stopped)
        } catch let error as URLError where error.code == .cancelled {
            livePreviews[bot.id] = LivePreview(status: .stopped)
        } catch let error as URLError where Self.isNotAnswering(error) {
            // darkmux's app connection isn't running: say so, with its command.
            livePreviews[bot.id] = LivePreview(status: .unavailable(.notAnswering))
        } catch let error as DarkmuxClient.ClientError {
            // darkmux won't run it: say why (a preview link you added is
            // still shown). Any other refusal is a failure.
            if let why = LivePreview.Unavailable.from(status: error.status, message: error.message, template: !bot.useCaseId.isEmpty, code: error.code) {
                Self.previewLog.info("preview \(name, privacy: .public): unavailable, \(String(describing: why), privacy: .public)")
                livePreviews[bot.id] = LivePreview(status: .unavailable(why))
                // No recipe in your checkout: the thread offers to set one up.
                if why == .noRecipe { noRecipe.insert(bot.id) }
            } else {
                Self.previewLog.error("preview \(name, privacy: .public) refused (\(error.status)): \(error.message, privacy: .public)")
                livePreviews[bot.id] = LivePreview(status: .failed(error.message))
            }
        } catch {
            Self.previewLog.error("preview \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            livePreviews[bot.id] = LivePreview(status: .failed(error.localizedDescription))
        }
        // A failure is when Start over matters: ask darkmux again next time
        // (it may have been updated meanwhile).
        if livePreviews[bot.id]?.status.isFailed == true { startOverChecked = false }
    }

    private static let previewLog = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "preview")
    /// How long a preview may take to start (first installs are slow).
    var previewDeadline: TimeInterval = 15 * 60
    /// Tests answer preview start (true) and status (false) here.
    var previewFetcher: ((Bool) async throws -> LivePreview)?
    /// Previews asked for before the connection was there.
    private var waitingPreviews: [UUID: Bot] = [:]
    /// Tests watch retries here; nil starts them for real.
    var retryPreview: ((Bot) -> Void)?

    /// The darkmux connection is here: start the previews that were waiting.
    func connectionAttached() {
        let waiting = waitingPreviews.values
        waitingPreviews = [:]
        for bot in waiting {
            if let retryPreview { retryPreview(bot) } else { Task { await ensurePreview(for: bot) } }
        }
    }

    /// How long a preview keeps running after you leave its bot's thread.
    /// Coming back (or SwiftUI rebuilding the view) within it sends darkmux
    /// nothing, rather than a stop and then a new start.
    static let previewStopGrace: Duration = .seconds(30)
    /// The grace period's clock; tests move it themselves.
    var previewGraceSleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Stops waiting out their grace period, by bot.
    private var pendingStops: [UUID: Task<Void, Never>] = [:]

    /// You left the bot's thread: its preview stops after
    /// `previewStopGrace`, unless you come back first.
    func leavePreview(for bot: Bot) {
        guard bot.workspaceName != nil else { return }
        pendingStops[bot.id]?.cancel()
        pendingStops[bot.id] = Task { [weak self] in
            guard let self else { return }
            await self.previewGraceSleep(Self.previewStopGrace)
            guard !Task.isCancelled else { return }
            self.pendingStops[bot.id] = nil
            await self.stopPreview(for: bot)
        }
    }

    /// You're back in the bot's thread: a stop still waiting is called off.
    func returnToPreview(for bot: Bot) {
        pendingStops.removeValue(forKey: bot.id)?.cancel()
    }

    /// Stops the bot's preview now (the Stop button, a grace period that
    /// ran out).
    func stopPreview(for bot: Bot) async {
        guard let name = bot.workspaceName else { return }
        await stopPreview(bot.id, workspace: name)
    }

    private func stopPreview(_ id: UUID, workspace name: String) async {
        pendingStops.removeValue(forKey: id)?.cancel()
        // One that was waiting for the connection must not start later, unseen.
        if waitingPreviews.removeValue(forKey: id) != nil { livePreviews[id] = LivePreview(status: .stopped) }
        // Sent whenever this app asked darkmux for the preview, whatever it
        // shows now: failed, timed out, or "stopped" by a cancelled start.
        guard previewWorkspaces.removeValue(forKey: id) != nil else { return }
        livePreviews[id] = LivePreview(status: .stopped)
        if let previewStopper { await previewStopper(name); return }
        guard let connection, let token = connection.token else { return }
        try? await connection.client.stopPreview(token: token, workspace: name)
    }

    /// Stops every preview this app started: when the app quits. Gives up
    /// after `limit` so quitting never hangs; darkmux stops any preview
    /// still running once it has been idle.
    func stopAllPreviews(limit: Duration = .seconds(6)) async {
        let running = previewWorkspaces
        guard !running.isEmpty else { return }
        // Each stop marks its preview stopped at once, then asks darkmux; the
        // wait below ends when they're all answered or at `limit`, whichever
        // comes first (an unanswered stop is left to darkmux's idle timeout).
        stopsLeft = running.count
        for (id, name) in running {
            Task { await self.stopPreview(id, workspace: name); self.stopsLeft -= 1 }
        }
        let deadline = ContinuousClock.now + limit
        while stopsLeft > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// While a preview is on screen, asks darkmux its status every
    /// `previewHeartbeat`: darkmux stops a preview nobody has asked about
    /// for a while (`clients.preview.idle_minutes`), so this keeps the one
    /// you're looking at running. Returns when the task is cancelled.
    func keepPreviewAlive(for bot: Bot) async {
        guard let name = bot.workspaceName else { return }
        var misses = 0
        while !Task.isCancelled {
            if livePreviews[bot.id]?.status == .ready {
                do {
                    let p: LivePreview
                    if let previewFetcher {
                        p = try await previewFetcher(false)
                    } else if let connection, let token = connection.token {
                        p = try await connection.client.previewStatus(token: token, workspace: name).live
                    } else {
                        p = LivePreview(status: .ready)
                    }
                    misses = 0
                    if !Task.isCancelled, p.status != .ready || p.url != nil { livePreviews[bot.id] = p }
                } catch let error as DarkmuxClient.ClientError where error.status == 404 {
                    // darkmux no longer has it (restarted, idle-stopped).
                    if !Task.isCancelled { livePreviews[bot.id] = LivePreview(status: .stopped) }
                } catch {
                    // darkmux went away: after a few misses, say so (Try again).
                    misses += 1
                    if misses >= 3, !Task.isCancelled { livePreviews[bot.id] = LivePreview(status: .unavailable(.notAnswering)) }
                }
            }
            try? await Task.sleep(for: previewHeartbeat)
        }
    }

    /// How often a preview on screen tells darkmux it's still wanted.
    var previewHeartbeat: Duration = .seconds(60)
    /// Quit's stops still waiting on darkmux.
    private var stopsLeft = 0
    /// Workspace names of the previews this app asked for, by bot.
    private var previewWorkspaces: [UUID: String] = [:]
    /// Tests watch stops here; nil asks darkmux.
    var previewStopper: ((String) async -> Void)?

    // MARK: Work copies

    enum WorkCopySetup: Equatable { case settingUp, failed(String) }
    /// What darkmux said when a work copy failed, behind Show details.
    var workCopyDetails: [UUID: String] = [:]
    /// What darkmux said when Undo was refused, behind Show details.
    var decisionDetails: [UUID: String] = [:]

    /// A Stop darkmux refused: one that raced the run's end had nothing left
    /// to stop.
    static func stopFailure(_ error: any Error) -> String {
        if let client = error as? DarkmuxClient.ClientError,
           client.status == 409 || client.message.localizedCaseInsensitiveContains("not running") {
            return String(localized: "It had already finished.")
        }
        return String(localized: "Couldn't stop it: \(DarkmuxPlain.sentence(error))")
    }

    /// The thread's line when a run starts, with the crew's name (never
    /// darkmux's role, "analyst" or "code-reviewer").
    nonisolated static func runningLine(crew: CrewRole, profile: String?) -> String {
        if let profile { return String(localized: "Running on darkmux: \(crew.name), on \(profile).") }
        return String(localized: "Running on darkmux: \(crew.name).")
    }
    /// Work copies being set up (or that failed), by bot.
    var workCopySetup: [UUID: WorkCopySetup] = [:]
    /// Finds a backed-up template bot's start on GitHub (tests); else
    /// `GitHubRepoMaker.findStart` with your sign-in.
    var startFinder: ((String, TemplateEntry) async -> (GitHubPR.Start, String)?)?

    /// Asks darkmux for the bot's workspace on this Mac: a worktree of the
    /// folder you picked (on its own branch, from the fetched default
    /// branch), else a clone of its GitHub repo. Stores only the name.
    func setUpWorkCopy(for bot: Bot, store: BotStore, sourcePath: String? = nil, template: TemplateEntry? = nil) async {
        let token = connection?.token
        guard workspaceMaker != nil || token != nil else {
            // Not a failure: the card already asks you to pair, and nothing
            // stale is left to show once you have.
            workCopySetup[bot.id] = nil
            return
        }
        var template = template
        // A template bot made while unpaired or on iPhone: its project is
        // made here from the same template, at its pinned commit.
        // Backed up to GitHub from there, it keeps its repo: the project is
        // still made from the template, at the commit its repo started from,
        // and its GitHub start (only on the device that made it) is found
        // again, so backups go on.
        if template == nil, sourcePath == nil, !bot.useCaseId.isEmpty, bot.folderBookmark == nil {
            workCopySetup[bot.id] = .settingUp
            let id = bot.useCaseId
            guard var entry = await (templateSource ?? Self.registryTemplate)(id) else {
                workCopySetup[bot.id] = .failed(String(localized: "its template (\(id)) isn't in the template list anymore"))
                return
            }
            // Backed up to GitHub: made only once its start there is known,
            // or it could never be backed up or opened as a PR.
            if let repo = bot.repoSlugs.first, bot.githubStart == nil {
                guard let found = await findStart(repo: repo, template: entry, botName: bot.name) else {
                    workCopySetup[bot.id] = .failed(startFinder == nil && githubToken?() == nil
                        ? String(localized: "Sign in with GitHub (Settings › GitHub) so I can find where this project starts on GitHub, then make the project again.")
                        : String(localized: "I couldn't find where this project starts on GitHub (its “Start from …” commit), so I didn't make it here. Try again in a moment."))
                    return
                }
                bot.githubStart = found.0
                entry.ref = found.1
            }
            template = entry
        }
        let bodyAndAccess = template.map {
            (body: DarkmuxClient.WorkspaceBody?.some(.init(repoURL: $0.repoURL, sourcePath: nil, bot: bot.name, template: true, ref: $0.ref)), release: {})
        } ?? sourcePath.map { (body: DarkmuxClient.WorkspaceBody?.some(.init(repoURL: nil, sourcePath: $0, bot: bot.name)), release: {}) }
            ?? workspaceRequest(for: bot)
        guard let body = bodyAndAccess.body else {
            workCopySetup[bot.id] = .failed(RunBlocker.noCode.message)
            return
        }
        defer { bodyAndAccess.release() }
        workCopySetup[bot.id] = .settingUp
        do {
            let made: DarkmuxClient.Workspace
            if let workspaceMaker {
                made = try await workspaceMaker(body)
            } else if let connection, let token {
                made = try await connection.client.setUpWorkspace(token: token, body)
            } else {
                return
            }
            // Another work copy: the old one's preview stops and is forgotten,
            // never shown for the new project.
            if let old = previewWorkspaces[bot.id], old != made.workspace {
                await stopPreview(bot.id, workspace: old)
                livePreviews[bot.id] = nil
            }
            bot.workspaceName = made.workspace
            bot.workspaceMachine = FleetConnection.machineName
            // A template's project is local: its origin is never the bot's repo.
            if template == nil, bot.repoSlugs.isEmpty, let repo = made.repo, let slug = GitHubIssue.repoSlug(from: repo) {
                store.addResource(.repo, "https://github.com/\(slug)", to: bot)
            }
            store.save()
            workCopySetup[bot.id] = nil
            let branch = made.branch.map { $0.isEmpty ? "" : ", branch \($0)" } ?? ""
            store.append(.system, "Work copy ready on \(FleetConnection.machineName)\(branch).", to: store.conversation(for: .bot(bot.id)))
            if made.fetchError != nil { store.append(.system, Self.staleBase, to: store.conversation(for: .bot(bot.id))) }
            let key = RecipeStore.key(for: bot)
            if let key { recipes.recipes[key] = nil; await recipes.load(for: key, workspace: made.workspace, connection: connection, github: github, useCaseId: bot.useCaseId) }
        } catch {
            workCopySetup[bot.id] = .failed(DarkmuxPlain.sentence(error))
            workCopyDetails[bot.id] = DarkmuxPlain.details(error)
        }
    }

    private func findStart(repo: String, template: TemplateEntry, botName: String) async -> (GitHubPR.Start, String)? {
        if let startFinder { return await startFinder(repo, template) }
        guard let token = githubToken?() else { return nil }
        guard let found = try? await GitHubRepoMaker(token: token).findStart(repo: repo, template: template, botName: botName) else { return nil }
        return (found.start, found.ref)
    }

    /// Tests stand in for darkmux's work API here; nil uses the client.
    var workSubmitter: ((_ role: String, _ message: String, _ profile: String?, _ workspace: String, _ continues: String?) async throws -> (String, String?))?
    var workCanceller: ((String) async throws -> Void)?
    /// Runs being followed now (each by exactly one loop).
    private var following: Set<UUID> = []
    /// Tests answer a run's status here.
    var workStatusFetcher: ((String) async throws -> DarkmuxClient.WorkStatus)?
    /// Tests poll faster than darkmux's backoff.
    var pollInterval: Double?
    /// Runs being handed to darkmux right now (approved, no work id yet).
    private var starting: Set<UUID> = []

    /// Records that this device started `run`: its darkmux is this Mac's.
    func markStartedHere(_ run: BotRun) {
        guard let bot = run.bot else { return }
        let id = run.id.uuidString
        LocalBotState.shared.update(bot.id) { entry in
            var ids = entry.localRuns ?? []
            if !ids.contains(id) { ids.append(id) }
            entry.localRuns = Array(ids.suffix(500))
        }
    }

    /// Runs from before this device recorded the runs it starts: a bot
    /// with a work copy on this Mac adopts its finished runs (so Undo works
    /// on them here), once. Running ones are left alone: whose darkmux has
    /// them can't be told.
    func adoptLegacyRuns(store: BotStore) {
        for bot in store.allBots() where bot.workspaceName != nil && LocalBotState.shared[bot.id]?.localRuns == nil {
            let ids = (bot.runs ?? []).filter { $0.phase != .running }.map(\.id.uuidString)
            LocalBotState.shared.update(bot.id) { $0.localRuns = Array(ids.suffix(500)) }
        }
    }

    /// A Tweak's change with the element you picked for it (a pick sent
    /// while tweaking is never dropped).
    static func tweakChange(_ text: String, element: PickedElement?) -> String {
        guard let element else { return text }
        let quoted = element.selectedText.flatMap { $0.isEmpty ? nil : ", the text “\($0)”" } ?? ""
        let about = "(`\(element.selector)` on \(element.url)\(quoted))"
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "About \(about)" : "\(text) \(about)"
    }

    /// Why a done-when check couldn't run, by run (the card offers Check again).
    var checkProblems: [UUID: String] = [:]
    static let checkNotRunning = String(localized: "Couldn't check: the preview wasn't running.")
    /// Checks waiting for their bot's preview to be ready.
    private var pendingChecks: Set<UUID> = []

    private func runPendingChecks(for bot: Bot) {
        for run in bot.runs ?? [] where pendingChecks.contains(run.id) {
            pendingChecks.remove(run.id)
            Task { await self.check(run) }
        }
    }

    /// darkmux's app connection isn't answering on this Mac.
    nonisolated static func isNotAnswering(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut].contains(error.code)
    }

    /// The darkmux work ids of a run, oldest first: the run and each Tweak
    /// (its own commit). Kept on this Mac (LocalBotState), never synced.
    func recordWork(_ workId: String, for run: BotRun) {
        guard let bot = run.bot else { return }
        LocalBotState.shared.update(bot.id) { entry in
            var all = entry.runWorkIds ?? [:]
            var ids = all[run.id.uuidString] ?? []
            if !ids.contains(workId) { ids.append(workId) }
            all[run.id.uuidString] = ids
            entry.runWorkIds = all
        }
    }

    func workIds(for run: BotRun) -> [String] {
        let kept = run.bot.flatMap { LocalBotState.shared[$0.id]?.runWorkIds?[run.id.uuidString] } ?? []
        if kept.isEmpty { return run.darkmuxWorkId.map { [$0] } ?? [] }
        return kept
    }

    private func forgetWork(_ workId: String, for run: BotRun) {
        guard let bot = run.bot else { return }
        LocalBotState.shared.update(bot.id) { entry in
            entry.runWorkIds?[run.id.uuidString]?.removeAll { $0 == workId }
        }
    }

    /// The work copy's base couldn't be fetched (darkmux's fetch_error).
    static let staleBase = String(localized: "darkmux couldn't get the latest from GitHub, so this work copy may be behind it.")
    /// darkmux runs two at a time for this app (429 too_many_requests).
    static let waitingForSlot = String(localized: "Waiting for a free slot: darkmux runs two of this app's runs at a time. It starts when one finishes.")

    /// Runs darkmux had no room for, oldest first, with what to send.
    private var queued: [(run: BotRun, message: String, continues: String?)] = []

    /// One of this app's runs ended: start the next one waiting for a slot.
    func slotFreed(store: BotStore) {
        while let next = queued.first {
            queued.removeFirst()
            guard next.run.phase == .running else { continue }
            _ = startRealRun(next.run, message: next.message, store: store, continues: next.continues)
            return
        }
    }

    /// Runs "Run again with these numbers" is planning (one tap at a time).
    var rerunning: Set<UUID> = []

    /// A result as it was before a Tweak: put back when the Tweak doesn't
    /// start, fails or is stopped, so its Undo and Open PR are never lost.
    struct TweakBase: Codable, Equatable, Sendable {
        var summary: String
        var changedFiles: [String]
        var diff: String?
        var keptCommit: String?
        var keptBranch: String?
        var details: String?
        var finishedAt: Date?
        /// The turn the Tweak continues: the run's darkmux work id until the
        /// Tweak's own is accepted.
        var workId: String? = nil
    }

    /// Kept on this Mac (`LocalBotState`), so it survives a relaunch.
    func tweakBase(_ run: BotRun) -> TweakBase? {
        run.bot.flatMap { LocalBotState.shared[$0.id]?.tweakBases?[run.id.uuidString] }
    }

    private func setTweakBase(_ run: BotRun, _ base: TweakBase?) {
        guard let bot = run.bot else { return }
        LocalBotState.shared.update(bot.id) { entry in
            var bases = entry.tweakBases ?? [:]
            bases[run.id.uuidString] = base
            entry.tweakBases = bases.isEmpty ? nil : bases
        }
    }

    /// Puts a Tweak's run back to the result it continued, saying why.
    private func restoreTweak(_ run: BotRun, store: BotStore, saying line: String) {
        guard let base = tweakBase(run) else { return }
        setTweakBase(run, nil)
        if run.darkmuxWorkId == nil { run.darkmuxWorkId = base.workId }
        run.summary = base.summary
        run.changedFiles = base.changedFiles
        run.diff = base.diff
        run.keptCommit = base.keptCommit
        run.keptBranch = base.keptBranch
        run.details = base.details
        run.finishedAt = base.finishedAt
        run.phase = .result
        if let bot = run.bot {
            store.append(.system, line, to: store.conversation(for: .bot(bot.id)))
            store.refreshState(of: bot)
        }
        store.save()
    }

    static let tweakQuitBeforeStart = String(localized: "The change didn't start before Mux Bot quit. The result before it is unchanged; reply to try again.")
    static let stopUnpaired = String(localized: "Pair Mux Bot with darkmux again to stop it.")
    static let stopElsewhere = String(localized: "Stop it from the Mac it runs on.")

    /// Before a bot is deleted: its runs on this Mac are cancelled on
    /// darkmux and its preview stopped. A problem (darkmux wouldn't cancel a
    /// run) is returned, and the bot must not be deleted.
    func prepareToDelete(_ bot: Bot, store: BotStore) async -> String? {
        for run in bot.runs ?? [] where run.phase == .running && run.startedHere {
            if let workId = run.darkmuxWorkId {
                do {
                    if let workCanceller { try await workCanceller(workId) } else if let connection, let token = connection.token {
                        try await connection.client.cancelWork(token: token, workId: workId)
                    } else {
                        return String(localized: "\(bot.name) still has a run on darkmux, and this app isn't paired to stop it. Pair again, then delete it.")
                    }
                } catch {
                    return String(localized: "darkmux didn't stop “\(run.task)”, so \(bot.name) wasn't deleted: \(DarkmuxPlain.sentence(error))")
                }
            }
            store.apply(.stop, to: run)
        }
        await stopPreview(for: bot)
        return nil
    }
    var workUndoer: ((String) async throws -> DarkmuxClient.UndoResult)?

    /// Tests answer workspace requests here; nil asks darkmux.
    /// Bots whose project has no preview recipe darkmux will run (its 404).
    var noRecipe: Set<UUID> = []
    /// Posts a run's notice (tests); else the notification service.
    var noticePoster: ((RunNotice, UUID) async -> Void)?
    /// Your GitHub sign-in's token, for backups (set by the app).
    var githubToken: (@MainActor () -> String?)?
    /// darkmux's branch changes for a workspace (tests); else darkmux.
    var changesFetcher: ((String) async throws -> DarkmuxClient.Changes)?
    /// Pushes a backup (tests); else `GitHubPR.push`.
    var prPusher: ((DarkmuxClient.Changes, String, String, UUID, GitHubPR.Start?) async throws -> GitHubPR.Pushed)?
    var workspaceMaker: ((DarkmuxClient.WorkspaceBody) async throws -> DarkmuxClient.Workspace)?
    /// Finds a use case's template by id (tests); else the template registry.
    var templateSource: ((String) async -> TemplateEntry?)?

    private static func registryTemplate(_ id: String) async -> TemplateEntry? {
        await TemplateRegistry.shared.templates().first { $0.id == id }
    }

    /// The request for a bot's workspace, with folder access held until
    /// `release` (the picked folder is security-scoped).
    private func workspaceRequest(for bot: Bot) -> (body: DarkmuxClient.WorkspaceBody?, release: () -> Void) {
        if let data = bot.folderBookmark, let url = Self.resolve(bookmark: data) {
            let accessing = url.startAccessingSecurityScopedResource()
            return (DarkmuxClient.WorkspaceBody(repoURL: nil, sourcePath: url.path, bot: bot.name),
                    { if accessing { url.stopAccessingSecurityScopedResource() } })
        }
        if let repo = bot.repoSlugs.first {
            return (DarkmuxClient.WorkspaceBody(repoURL: "https://github.com/\(repo)", sourcePath: nil, bot: bot.name), {})
        }
        return (nil, {})
    }

    nonisolated static func resolve(bookmark: Data) -> URL? {
        var stale = false
        #if os(macOS)
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
    }

    /// A folder you picked with the Open panel: it must be a git checkout.
    /// Its GitHub repo (from `origin`) becomes the bot's repo, and darkmux
    /// makes a worktree of it so runs never touch your own working tree.
    /// Returns a plain sentence when the folder can't be used.
    @discardableResult
    func addFolder(_ url: URL, to bot: Bot, store: BotStore) async -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard GitRemote.isRepository(url) else {
            return "\(url.lastPathComponent) isn't a git repository. Pick the top folder of a project you cloned with git."
        }
        #if os(macOS)
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        bot.folderBookmark = bookmark ?? Data()
        bot.folderName = url.lastPathComponent
        // A new work copy: the old one's preview stops and is forgotten.
        if let old = previewWorkspaces[bot.id] { await stopPreview(bot.id, workspace: old) }
        livePreviews[bot.id] = nil
        bot.workspaceName = nil
        if let slug = GitRemote.originSlug(of: url), !bot.repoSlugs.contains(slug) {
            store.addResource(.repo, "https://github.com/\(slug)", to: bot)
        }
        store.save()
        guard bookmark != nil else { return "I couldn't keep access to \(url.lastPathComponent). Pick it again." }
        if connection?.isPaired == true { await setUpWorkCopy(for: bot, store: store) }
        // Said on the card that asked (not only in the bot's info).
        if case let .failed(why)? = workCopySetup[bot.id] { return String(localized: "darkmux couldn't set up a work copy: \(why)") }
        return nil
    }

    /// Sends the run to darkmux when this app is paired, the crew role maps
    /// to a darkmux role, and the bot has a workspace on this Mac.
    /// Returns false otherwise.
    private func startRealRun(_ run: BotRun, message: String, store: BotStore, continues: String? = nil) -> Bool {
        guard let connection, let token = connection.token,
              let role = run.crew.darkmuxRole, let bot = run.bot,
              let workspace = bot.workspaceName else { return false }
        let submit = workSubmitter ?? { role, message, profile, workspace, continues in
            try await connection.client.submitWork(token: token, role: role, message: message, profile: profile,
                                                   workspace: workspace, continues: continues)
        }
        let thread = store.conversation(for: .bot(bot.id))
        markStartedHere(run)
        starting.insert(run.id)
        Task { @MainActor in
            defer { if run.darkmuxWorkId == nil { starting.remove(run.id) } }
            do {
                // darkmux picks the profile for this role (its role binding, else
                // the default) and checks it against what the owner granted.
                // The app's choice of model (`runProfiles`), else darkmux's default.
                if runProfiles[run.id] == nil { await chooseProfile(for: run) }
                // Stopped while the model was chosen: it never reaches darkmux.
                guard run.phase == .running else { return }
                let brief = Self.workBrief(message, recipe: recipes.recipe(for: bot), skills: BotSkill.relevant(bot.skills, to: run.task))
                let workId: String, profile: String?
                do {
                    (workId, profile) = try await submit(role, brief, runProfiles[run.id], workspace, continues)
                } catch let error as DarkmuxClient.ClientError where continues != nil && [404, 409].contains(error.status) {
                    // darkmux won't continue that run (too old, or it restarted):
                    // the change goes as a fresh run on the same work copy.
                    (workId, profile) = try await submit(role, brief, runProfiles[run.id], workspace, nil)
                }
                // Stopped while it was being submitted: darkmux just started it,
                // so stop it there too.
                guard run.phase == .running else {
                    if let workCanceller { try? await workCanceller(workId) } else { try? await connection.client.cancelWork(token: token, workId: workId) }
                    return
                }
                run.darkmuxWorkId = workId
                recordWork(workId, for: run)
                starting.remove(run.id)
                store.append(.system, Self.runningLine(crew: run.crew, profile: profile), to: thread)
                await follow(run, workId: workId, store: store)
            } catch let error as DarkmuxClient.ClientError where error.status == 429 {
                // darkmux is running two of this app's runs: wait for a slot.
                queued.append((run, message, continues))
                store.append(.system, Self.waitingForSlot, to: thread)
            } catch {
                starting.remove(run.id)
                if tweakBase(run) != nil {
                    restoreTweak(run, store: store, saying: String(localized: "The change didn't start on darkmux (\(DarkmuxPlain.sentence(error))) The result before it is unchanged; reply to try again."))
                } else {
                    store.apply(Self.startFailure(error), to: run)
                }
            }
        }
        return true
    }

    /// Sends a follow-up to the same run (and, once wired, the same worktree).
    // MARK: Choosing the model

    /// The profile each run goes to darkmux with, chosen by the app (in
    /// memory on this Mac, like `checkSpecs`); nil leaves it to darkmux.
    var runProfiles: [UUID: String] = [:]
    /// Tests list profiles here; nil asks darkmux (`GET /client/profiles`).
    var profileSource: (@MainActor () async throws -> [DarkmuxClient.ProfileInfo])?

    /// What this app may run a role on here (Coder's by default), and what
    /// answers now.
    func listedProfiles(role: String = "coder") async -> [DarkmuxClient.ProfileInfo] {
        do {
            let profiles: [DarkmuxClient.ProfileInfo]
            if let profileSourceByRole {
                profiles = try await profileSourceByRole(role)
            } else if let profileSource {
                profiles = try await profileSource()
            } else {
                guard let connection, let token = connection.token else {
                    listing = .failed(String(localized: "Mux Bot isn't paired with darkmux."))
                    return []
                }
                let list = try await connection.client.profiles(token: token, role: role)
                if let named = list.machine { machine = named }
                profiles = list.profiles
            }
            listing = .listed
            return profiles
        } catch {
            Self.modelsLog.error("GET /client/profiles failed: \(error.localizedDescription, privacy: .public)")
            listing = .failed(DarkmuxPlain.sentence(error))
            return []
        }
    }

    /// How the last look at darkmux's models went; Settings › Models says a
    /// failure instead of showing an empty list.
    var listing: ModelListing = .loading
    private static let modelsLog = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "models")

    /// The darkmux machine runs go to, as darkmux names it (`GET
    /// /client/profiles`): the same id from every device.
    var machine: DarkmuxClient.Machine? {
        didSet { if let machine, machine != oldValue { settingsStore.lastMachine = machine } }
    }
    /// Where model settings live (iCloud key-value when sync is on).
    var settingsStore = ModelSettingsStore.shared

    /// The machine's id; before darkmux has said, its endpoint.
    var machineKey: String {
        if let known = knownMachine { return known.id }
        let url = connection?.client.baseURL ?? DarkmuxClient().baseURL
        return "endpoint:\(url.host() ?? "localhost"):\(url.port ?? 8767)"
    }

    /// The darkmux machine model settings are about: darkmux's answer
    /// now, else the last one it gave (kept with the settings, so it's known
    /// after a relaunch and on your other devices). nil until darkmux has
    /// said once: model settings aren't shown or saved before then.
    var knownMachine: DarkmuxClient.Machine? { machine ?? settingsStore.lastMachine }

    /// The machine as the settings name it: its name on the Mac; "your Mac
    /// (name)" on iPhone, where runs never go to the phone itself.
    nonisolated static func machinePhrase(_ machine: DarkmuxClient.Machine?, onPhone: Bool) -> String {
        if onPhone { return machine.map { String(localized: "your Mac (\($0.name))") } ?? String(localized: "your Mac") }
        return machine?.name ?? String(localized: "this Mac")
    }

    var machinePhrase: String {
        #if os(iOS)
        Self.machinePhrase(knownMachine, onPhone: true)
        #else
        Self.machinePhrase(knownMachine, onPhone: false)
        #endif
    }

    /// A model being chosen for a card that had none when you tapped
    /// Approve (tests wait on it).
    var choosingModel: [UUID: Task<Void, Never>] = [:]
    /// Tests list a role's profiles here; else darkmux (`?role=`).
    var profileSourceByRole: ((String) async throws -> [DarkmuxClient.ProfileInfo])?
    /// What darkmux listed last for each role (each crew has its own).
    var listedByRole: [String: [DarkmuxClient.ProfileInfo]] = [:]

    /// The models a run's picker offers: its crew's own.
    func listed(for run: BotRun) -> [DarkmuxClient.ProfileInfo] {
        run.crew.darkmuxRole.flatMap { listedByRole[$0] } ?? lastListed
    }

    /// Settings › Models as they apply to runs on this machine.
    func currentModelSettings() -> ModelSettings { settingsStore.settings(machine: machineKey) }
    /// Why each run has its model, for the dispatch card.
    var runChoices: [UUID: ModelChoice] = [:]
    /// What darkmux listed last, for pickers.
    var lastListed: [DarkmuxClient.ProfileInfo] = []

    /// Picks the run's model by the bot's mode (else the app's): Auto, a
    /// default model, or Always ask. With `next`, it's a run again after a
    /// done-when that wasn't met.
    func chooseProfile(for run: BotRun, next: Bool = false, after previous: String? = nil) async {
        // Each crew's own models: darkmux lists a role's (`?role=`).
        let role = run.crew.darkmuxRole ?? "coder"
        let listed = await listedProfiles(role: role)
        listedByRole[role] = listed
        if role == "coder" { lastListed = listed }
        let settings = currentModelSettings()
        let mode = settings.mode(forBot: run.bot.flatMap { settingsStore.botMode(bot: $0.id, machine: machineKey) })
        let choice = ModelChoice.resolve(mode: mode, order: settings.order, listed: listed,
                                         previous: previous ?? runProfiles[run.id], rerunAfterNotMet: next, crew: run.crew.name)
        runChoices[run.id] = choice
        runProfiles[run.id] = choice.profile
    }

    /// Another model for this one run (the card's Change, or Auto's pick when
    /// the chosen one isn't running).
    func override(_ run: BotRun, with profile: String) {
        runProfiles[run.id] = profile
        runChoices[run.id] = ModelChoice(profile: profile, reason: "chosen for this run")
    }

    func profile(for run: BotRun) -> String? { runProfiles[run.id] }

    // MARK: Checking the done-when

    /// Measures pages (an offscreen web view in the app).
    var layoutProbe: (any LayoutProbing)?
    /// What to measure after each run, from the measurement its brief was
    /// built on. On this Mac, in memory: a relaunch drops unchecked ones.
    var checkSpecs: [UUID: LayoutCheck.Spec] = [:]
    /// The done-when, checked after the run.
    var runChecks: [UUID: LayoutCheck.Result] = [:]
    /// Runs being checked right now.
    var checking: Set<UUID> = []

    /// After a run that changed files: measure the preview again at the
    /// widths its brief named, and say whether the done-when holds.
    func check(_ run: BotRun) async {
        guard !run.changedFiles.isEmpty, let spec = checkSpecs[run.id], let probe = layoutProbe, let bot = run.bot else { return }
        checking.insert(run.id)
        defer { checking.remove(run.id) }
        checkProblems[run.id] = nil
        // The page on the bot's preview as it is now (it may have restarted
        // on another port since the brief); none running: wait for it.
        guard let root = previewURL(for: bot) else {
            pendingChecks.insert(run.id)
            checkProblems[run.id] = Self.checkNotRunning
            return
        }
        var parts = URLComponents(url: root, resolvingAgainstBaseURL: false)
        parts?.path = spec.page.path.isEmpty ? "/" : spec.page.path
        parts?.query = spec.page.query
        let page = parts?.url ?? root
        let after = await probe.measure(url: page, widths: spec.widths)
        guard !after.isEmpty else {
            pendingChecks.insert(run.id)
            checkProblems[run.id] = Self.checkNotRunning
            return
        }
        let result = LayoutCheck.evaluate(spec, after: after)
        runChecks[run.id] = result
        // A default model doesn't switch by itself: offer the next one.
        if !result.met, var choice = runChoices[run.id], choice.stays, let name = choice.profile {
            let settings = currentModelSettings()
            choice.offerNext = ModelChoice.resolve(mode: .model(name), order: settings.order, listed: lastListed,
                                                   previous: name, rerunAfterNotMet: true).offerNext
            runChoices[run.id] = choice
        }
    }

    /// The last message a Tweak composed (tests read it).
    private(set) var lastTweakMessage: String?

    /// `message` replaces the default "Earlier task / Now change this" one
    /// (an issue run's brief rebuilt from the issue, `BotBrain.rerunBrief`).
    func tweak(_ request: String, run: BotRun, store: BotStore, echo: Bool = true, message: String? = nil) {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let bot = run.bot else { return }
        // Undo in flight: a reply would continue a run that's being reverted.
        if deciding.contains(run.id) {
            store.append(.system, "Undo is still going; wait for it to finish, then reply.", to: store.conversation(for: .bot(bot.id)))
            return
        }
        let composed = message ?? Self.tweakMessage(for: run, change: text)
        lastTweakMessage = composed
        if echo { store.append(.user, text, to: store.conversation(for: .bot(bot.id))) }
        tweakRunId = nil
        if let reason = whyRunCannotStart(run) {
            store.append(.system, "Can't run this yet: \(reason).", to: store.conversation(for: .bot(bot.id)))
            return
        }
        let base = TweakBase(summary: run.summary, changedFiles: run.changedFiles, diff: run.diff, keptCommit: run.keptCommit,
                             keptBranch: run.keptBranch, details: run.details, finishedAt: run.finishedAt)
        guard store.apply(.tweak, to: run) else { return }
        // darkmux keeps a Tweak's changes together with the run it continues.
        let continues = run.darkmuxWorkId
        var kept = base
        kept.workId = continues
        setTweakBase(run, kept)
        // Until darkmux accepts the Tweak the run has no work id of its own:
        // the earlier turn's is never followed (or stopped) as the Tweak's.
        run.darkmuxWorkId = nil
        runChecks[run.id] = nil   // the last done-when result was about the earlier version
        _ = startRealRun(run, message: composed, store: store, continues: continues)
    }




    // MARK: Pull requests

    /// What GitHub or darkmux said behind a thread line, by message id
    /// (Show details; on this Mac, for this launch).
    var messageDetails: [UUID: String] = [:]

    /// A template project goes to GitHub only on top of its start there:
    /// never to darkmux's local branch name.
    func canPush(_ bot: Bot) -> Bool { bot.githubStart != nil || bot.useCaseId.isEmpty }

    /// Finds a template project's GitHub start when this Mac doesn't know it
    /// (made on another device, or the sign-in was missing then).
    @discardableResult
    func recoverStart(_ bot: Bot) async -> Bool {
        guard bot.githubStart == nil, !bot.useCaseId.isEmpty, let repo = bot.repoSlugs.first,
              let entry = await template(for: bot.useCaseId),
              let found = await findStart(repo: repo, template: entry, botName: bot.name) else { return bot.githubStart != nil }
        bot.githubStart = found.0
        return true
    }

    /// A failure in a plain sentence: darkmux's by status, GitHub's already
    /// are; the raw text goes behind Show details.
    static func plain(_ error: any Error) -> (sentence: String, details: String?) {
        if error is DarkmuxClient.ClientError { return (DarkmuxPlain.sentence(error), DarkmuxPlain.details(error)) }
        return (error.localizedDescription, String(describing: error))
    }

    /// GitHub's session for pushes and PRs (tests); else `.shared`.
    var githubSession: URLSession?
    /// Bots with a PR being opened (their button waits).
    var openingPR: Set<UUID> = []

    /// Why GitHub refused a write, from whether the App is installed there:
    /// the install link only when it isn't.
    nonisolated static func cantWriteText(_ repo: String, _ install: GitHubAuth.InstallState) -> String {
        switch install {
        case let .notInstalled(url):
            String(localized: "Install Mux Bot on \(repo) to open pull requests: \(url.absoluteString)")
        case .installed:
            String(localized: "Mux Bot's GitHub App is installed on \(repo), but GitHub still refused to let it write there. Check that the App has read and write access to the repo's contents and pull requests, then try again.")
        case .unknown:
            String(localized: "GitHub refused to let Mux Bot write to \(repo), and I couldn't check whether its GitHub App is installed there. Try again in a moment.")
        }
    }

    /// The bot's committed runs not yet in a PR from this thread.
    func unshippedRuns(_ bot: Bot, store: BotStore) -> [BotRun] {
        // Read on every redraw of the thread's toolbar: never makes a thread.
        let lastPR = max((store.existingConversation(for: .bot(bot.id))?.messages ?? [])
            .filter { $0.kind == .prCard }.map(\.timestamp).max() ?? .distantPast,
                         LocalBotState.shared[bot.id]?.shippedThrough ?? .distantPast)
        return (bot.runs ?? []).filter { $0.keptCommit != nil && $0.phase == .result && ($0.finishedAt ?? $0.createdAt) > lastPR }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Open PR shows when you're signed in to GitHub and the bot's branch has
    /// committed runs that aren't in a PR yet.
    func canOpenPR(_ bot: Bot, store: BotStore, github: GitHubAuth) -> Bool {
        github.token != nil && bot.workspaceName != nil && !bot.repoSlugs.isEmpty && !unshippedRuns(bot, store: store).isEmpty
    }

    /// Opens (or updates) the PR for the bot's branch: darkmux hands over the
    /// committed changes; the app creates the branch and PR with your GitHub
    /// sign-in. The link goes in the thread.
    func openPR(for bot: Bot, store: BotStore, github: GitHubAuth) async {
        let thread = store.conversation(for: .bot(bot.id))
        guard let token = github.token else {
            store.append(.system, "Sign in with GitHub (Settings › GitHub) to open pull requests.", to: thread); return
        }
        guard let workspace = bot.workspaceName, let repo = bot.repoSlugs.first, let connection, let darkmux = connection.token else {
            store.append(.system, "This bot needs a work copy and a GitHub repo to open a pull request.", to: thread); return
        }
        // A template project needs its start on GitHub (never its local
        // branch name): found again if this Mac doesn't know it.
        if !canPush(bot), !(await recoverStart(bot)) {
            store.append(.system, String(localized: "I don't know where this project starts on GitHub on this Mac, so I can't open a pull request for it yet. Sign in with GitHub (Settings › GitHub), then try again."), to: thread)
            return
        }
        openingPR.insert(bot.id)
        defer { openingPR.remove(bot.id) }
        await oneAtATime(bot.id) { [self] in
            await openPR(bot, workspace: workspace, repo: repo, token: token, darkmux: darkmux, connection: connection,
                         store: store, github: github, thread: thread)
        }
    }

    private func openPR(_ bot: Bot, workspace: String, repo: String, token: String, darkmux: String, connection: FleetConnection,
                        store: BotStore, github: GitHubAuth, thread: ChatConversation) async {
        do {
            let readAt = Date()
            let changes = try await changes(for: workspace)
            guard !changes.files.isEmpty else {
                store.append(.system, "Nothing to open a PR with: \(changes.branch) has no changes against \(changes.baseBranch).", to: thread); return
            }
            let runs = unshippedRuns(bot, store: store)
            let text = PRText.make(bot: bot, runs: runs, machine: FleetConnection.machineName)
            let approved = LocalBotState.shared[bot.id]?.prFiles ?? [:]
            let pr = try await pushMovingOn(bot, changes: changes, store: store) {
                try await GitHubPR(session: githubSession ?? .shared, token: token).open(changes, repo: repo, title: text.title, body: text.body, bot: bot.id,
                                                      extraFiles: approved, start: $0)
            }
            store.append(.system, "Opened PR #\(pr.number): \(pr.url.absoluteString)", kind: .prCard, runId: runs.last?.id, to: thread)
            // Its runs are in this PR now, even after the thread is cleared.
            LocalBotState.shared.update(bot.id) { $0.shippedThrough = max($0.shippedThrough ?? .distantPast, readAt) }
            for path in pr.added { store.append(.system, String(localized: "Added \(path), which you approved, to the pull request."), to: thread) }
            for (path, why) in pr.skipped.sorted(by: { $0.key < $1.key }) {
                switch why {
                case .inChanges: store.append(.system, String(localized: "Left out \(path) you approved: the bot's changes already have one, and I don't write over it."), to: thread)
                case .inBase:
                    // It's in the repo now: nothing more to carry.
                    LocalBotState.shared.update(bot.id) { $0.prFiles?[path] = nil }
                    store.append(.system, String(localized: "Left out \(path) you approved: the repo already has one, and I don't write over it."), to: thread)
                }
            }
        } catch GitHubPR.Failure.cantWrite(let repo) {
            let install = await github.installState(for: repo)
            store.append(.system, Self.cantWriteText(repo, install), to: thread)
        } catch {
            let said = Self.plain(error)
            let line = store.append(.system, String(localized: "Couldn't open the PR: \(said.sentence)"), to: thread)
            messageDetails[line.id] = said.details
        }
    }
}

extension BotRun {
    /// Started from this device, so this Mac's darkmux has it. Runs synced
    /// from another Mac aren't followed, stopped or undone from here.
    @MainActor var startedHere: Bool {
        guard let bot, let local = LocalBotState.shared[bot.id]?.localRuns else { return false }
        return local.contains(id.uuidString)
    }
}
