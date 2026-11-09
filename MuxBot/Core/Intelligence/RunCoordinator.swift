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
        didSet { if connection != nil { connectionAttached() } }
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
        guard run.phase == .result, !deciding.contains(run.id), let bot = run.bot,
              let workId = run.darkmuxWorkId, let connection, let token = connection.token else {
            if connection?.token == nil { decisionErrors[run.id] = "Can't do that yet: \(RunBlocker.unpaired.message)." }
            return
        }
        let thread = store.conversation(for: .bot(bot.id))
        deciding.insert(run.id)
        defer { deciding.remove(run.id) }
        do {
            let undone = try await connection.client.undoWork(token: token, workId: workId)
            store.append(.system, RunResultText.discarded(restored: undone.files, removed: []).replacingOccurrences(of: "Put back", with: "Undone: put back"), to: thread)
            decisionErrors[run.id] = nil
            store.apply(.discard, to: run)
        } catch let error as DarkmuxClient.ClientError where error.status == 404 {
            // darkmux restarted and no longer tracks the run; its commit is
            // still in the work copy's history.
            let commit = run.keptCommit.map { " Its commit is \($0)\(run.keptBranch.map { " on \($0)" } ?? "")." } ?? ""
            decisionErrors[run.id] = "darkmux no longer tracks this run, so it can't undo it from here.\(commit)"
        } catch let error as DarkmuxClient.ClientError {
            decisionErrors[run.id] = RunResultText.undoRefusal(error.message, runs: bot.runs ?? [])
        } catch {
            decisionErrors[run.id] = "Couldn't undo it: \(error.localizedDescription)"
        }
    }

    /// Every darkmux run gets the same working rules after its task, plus
    /// the repo's own hints from its `.darkmux/preview.json`, never a guess
    /// about how some other kind of project is laid out.
    nonisolated static func workBrief(_ task: String, recipe: PreviewManifest? = nil) -> String {
        let hints = recipe?.conventions.map { "\n\nAbout this repository: \($0)" } ?? ""
        return task + hints + """


            You are working in this repository (the current directory). Find the file responsible, \
            make the smallest change that does it, and change nothing else. Don't run installs, builds \
            or the dev server. If you can't find where to change, stop and say what you searched instead \
            of repeating searches. When done, list the files you changed.
            """
    }

    /// darkmux refusing or not answering a submit fails the run; it is never
    /// a result to Keep.
    nonisolated static func startFailure(_ error: any Error) -> RunEvent {
        .fail(reason: "Couldn't start on darkmux", details: error.localizedDescription)
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

    private func follow(_ run: BotRun, workId: String, token: String, client: DarkmuxClient, store: BotStore) async {
        var backoff = PollBackoff()
        defer { unreachableRuns.remove(run.id) }
        while run.phase == .running, run.darkmuxWorkId == workId {
            try? await Task.sleep(for: .seconds(backoff.delay))
            let status: DarkmuxClient.WorkStatus
            do {
                status = try await client.workStatus(token: token, workId: workId)
                backoff.succeeded()
                unreachableRuns.remove(run.id)
            } catch let error as DarkmuxClient.ClientError where error.status == 404 {
                // darkmux no longer knows this run (restarted, or it ended long ago):
                // show it as stopped rather than spinning forever.
                store.apply(.stop, to: run)
                return
            } catch {
                // darkmux unreachable: back off, say so after three misses, keep trying.
                backoff.failed()
                if backoff.isUnreachable { unreachableRuns.insert(run.id) }
                continue
            }
            switch status.status {
            case "running", "cancelling": continue
            case "cancelled": store.apply(.stop, to: run); return
            case "done":
                let report = status.finalAssistant ?? ""
                run.notes = report.isEmpty ? nil : report
                run.changedFiles = (status.changes?.files ?? []).map { f in
                    "\(f.path) +\(f.added ?? 0) −\(f.removed ?? 0)"
                }
                run.diff = status.changes?.diff
                // darkmux committed the changes to the work copy's branch.
                run.keptCommit = status.commit
                run.keptBranch = status.branch
                if let why = status.commitError { run.details = why }
                let summary = await summarize(report: report, files: (status.changes?.files ?? []).map(\.path), botName: run.bot?.name)
                store.apply(.finish(summary: summary), to: run)
                if !run.changedFiles.isEmpty, checkSpecs[run.id] != nil {
                    // Give the preview's hot reload a moment, then check.
                    Task { try? await Task.sleep(for: .seconds(2)); await self.check(run) }
                }
                if let notice = RunNotice.make(for: run) { await notifier?.post(notice, runId: run.id) }
                return
            default:
                switch RunResultText.classify(error: status.error ?? "", reason: status.reason) {
                case .stopped: store.apply(.stop, to: run)
                case let .failed(why):
                    store.apply(.fail(reason: "Didn't finish: \(why)", details: RunResultText.withoutPlumbing(status.error ?? "")), to: run)
                    if let notice = RunNotice.make(for: run) { await notifier?.post(notice, runId: run.id) }
                }
                return
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
        guard let connection, let token = connection.token else { return }
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
        for run in runs where run.phase == .running {
            guard let workId = run.darkmuxWorkId else { continue }
            Task { await follow(run, workId: workId, token: token, client: connection.client, store: store) }
        }
    }

    /// Stops a running run: darkmux cancels it (TERM, then KILL, and its
    /// container); the card shows it stopped.
    func stop(_ run: BotRun, store: BotStore) async {
        guard run.phase == .running else { return }
        if let workId = run.darkmuxWorkId, let connection, let token = connection.token {
            do {
                try await connection.client.cancelWork(token: token, workId: workId)
            } catch {
                if let bot = run.bot {
                    store.append(.system, "Couldn't stop it on darkmux: \(error.localizedDescription)", to: store.conversation(for: .bot(bot.id)))
                }
                return
            }
        }
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
    func ensurePreview(for bot: Bot) async {
        guard let name = bot.workspaceName else {
            Self.previewLog.debug("preview \(bot.name, privacy: .public): no work copy, nothing to start")
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
        if let status = livePreviews[bot.id]?.status, status != .stopped, status != .waiting, !(status.isFailed) {
            Self.previewLog.debug("preview \(name, privacy: .public): already \(String(describing: status), privacy: .public)")
            return
        }
        Self.previewLog.info("preview \(name, privacy: .public): asking darkmux to start it")
        livePreviews[bot.id] = LivePreview(status: .starting)
        do {
            var p = try await connection.client.startPreview(token: token, workspace: name).live
            livePreviews[bot.id] = p
            let deadline = Date().addingTimeInterval(15 * 60)
            while [.starting, .installing].contains(p.status), Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                p = try await connection.client.previewStatus(token: token, workspace: name).live
                livePreviews[bot.id] = p
            }
            Self.previewLog.info("preview \(name, privacy: .public): \(String(describing: p.status), privacy: .public)")
        } catch let error as DarkmuxClient.ClientError where error.status == 404 {
            Self.previewLog.info("preview \(name, privacy: .public): the repo has no preview recipe")
            livePreviews[bot.id] = nil   // no recipe: fall back to a preview link, if any
        } catch {
            Self.previewLog.error("preview \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            livePreviews[bot.id] = LivePreview(status: .failed(error.localizedDescription))
        }
    }

    private static let previewLog = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "preview")
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

    func stopPreview(for bot: Bot) async {
        guard let name = bot.workspaceName, let connection, let token = connection.token else { return }
        try? await connection.client.stopPreview(token: token, workspace: name)
        livePreviews[bot.id] = LivePreview(status: .stopped)
    }

    // MARK: Work copies

    enum WorkCopySetup: Equatable { case settingUp, failed(String) }
    /// Work copies being set up (or that failed), by bot.
    var workCopySetup: [UUID: WorkCopySetup] = [:]

    /// Asks darkmux for the bot's workspace on this Mac: a worktree of the
    /// folder you picked (on its own branch, from the fetched default
    /// branch), else a clone of its GitHub repo. Stores only the name.
    func setUpWorkCopy(for bot: Bot, store: BotStore, sourcePath: String? = nil) async {
        guard let connection, let token = connection.token else {
            workCopySetup[bot.id] = .failed(RunBlocker.unpaired.message)
            return
        }
        let bodyAndAccess = sourcePath.map { (body: DarkmuxClient.WorkspaceBody?.some(.init(repoURL: nil, sourcePath: $0, bot: bot.name)), release: {}) }
            ?? workspaceRequest(for: bot)
        guard let body = bodyAndAccess.body else {
            workCopySetup[bot.id] = .failed(RunBlocker.noCode.message)
            return
        }
        defer { bodyAndAccess.release() }
        workCopySetup[bot.id] = .settingUp
        do {
            let made = try await connection.client.setUpWorkspace(token: token, body)
            bot.workspaceName = made.workspace
            bot.workspaceMachine = FleetConnection.machineName
            if bot.repoSlugs.isEmpty, let repo = made.repo, let slug = GitHubIssue.repoSlug(from: repo) {
                store.addResource(.repo, "https://github.com/\(slug)", to: bot)
            }
            store.save()
            workCopySetup[bot.id] = nil
            let branch = made.branch.map { $0.isEmpty ? "" : ", branch \($0)" } ?? ""
            store.append(.system, "Work copy ready on \(FleetConnection.machineName)\(branch).", to: store.conversation(for: .bot(bot.id)))
            if let repo = bot.repoSlugs.first { recipes.recipes[repo] = nil; await recipes.load(for: repo, workspace: made.workspace, connection: connection, github: github) }
        } catch {
            workCopySetup[bot.id] = .failed(error.localizedDescription)
        }
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
        bot.workspaceName = nil
        if let slug = GitRemote.originSlug(of: url), !bot.repoSlugs.contains(slug) {
            store.addResource(.repo, "https://github.com/\(slug)", to: bot)
        }
        store.save()
        guard bookmark != nil else { return "I couldn't keep access to \(url.lastPathComponent). Pick it again." }
        if connection?.isPaired == true { await setUpWorkCopy(for: bot, store: store) }
        return nil
    }

    /// Sends the run to darkmux when this app is paired, the crew role maps
    /// to a darkmux role, and the bot has a workspace on this Mac.
    /// Returns false otherwise.
    private func startRealRun(_ run: BotRun, message: String, store: BotStore, continues: String? = nil) -> Bool {
        guard let connection, let token = connection.token,
              let role = run.crew.darkmuxRole, let bot = run.bot,
              let workspace = bot.workspaceName else { return false }
        let thread = store.conversation(for: .bot(bot.id))
        Task { @MainActor in
            do {
                // darkmux picks the profile for this role (its role binding, else
                // the default) and checks it against what the owner granted.
                // The app's choice of model (`runProfiles`), else darkmux's default.
                if runProfiles[run.id] == nil { await chooseProfile(for: run) }
                let (workId, profile) = try await connection.client.submitWork(token: token, role: role,
                                                                               message: Self.workBrief(message, recipe: recipes.recipe(for: bot)),
                                                                               profile: runProfiles[run.id], workspace: workspace, continues: continues)
                run.darkmuxWorkId = workId
                store.append(.system, "Running on darkmux: \(role)\(profile.map { " on \($0)" } ?? "").", to: thread)
                await follow(run, workId: workId, token: token, client: connection.client, store: store)
            } catch {
                store.apply(Self.startFailure(error), to: run)
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

    /// What this app may run Coder on here, and what answers now.
    func listedProfiles() async -> [DarkmuxClient.ProfileInfo] {
        do {
            let profiles: [DarkmuxClient.ProfileInfo]
            if let profileSource {
                profiles = try await profileSource()
            } else {
                guard let connection, let token = connection.token else {
                    listing = .failed(String(localized: "Mux Bot isn't paired with darkmux."))
                    return []
                }
                let list = try await connection.client.profiles(token: token)
                if let named = list.machine { machine = named }
                profiles = list.profiles
            }
            listing = .listed
            return profiles
        } catch {
            Self.modelsLog.error("GET /client/profiles failed: \(error.localizedDescription, privacy: .public)")
            listing = .failed(error.localizedDescription)
            return []
        }
    }

    /// How the last look at darkmux's models went; Settings › Models says a
    /// failure instead of showing an empty list.
    var listing: ModelListing = .loading
    private static let modelsLog = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "models")

    /// The darkmux machine runs go to, as darkmux names it (`GET
    /// /client/profiles`): the same id from every device.
    var machine: DarkmuxClient.Machine?
    /// Where model settings live (iCloud key-value when sync is on).
    var settingsStore = ModelSettingsStore.shared

    /// The machine's id; before darkmux has said, its endpoint.
    var machineKey: String {
        if let machine { return machine.id }
        let url = connection?.client.baseURL ?? DarkmuxClient().baseURL
        return "endpoint:\(url.host() ?? "localhost"):\(url.port ?? 8767)"
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
        let listed = await listedProfiles()
        lastListed = listed
        let settings = currentModelSettings()
        let mode = settings.mode(forBot: run.bot.flatMap { settingsStore.botMode(bot: $0.id, machine: machineKey) })
        let choice = ModelChoice.resolve(mode: mode, order: settings.order, listed: listed,
                                         previous: previous ?? runProfiles[run.id], rerunAfterNotMet: next)
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
        guard !run.changedFiles.isEmpty, let spec = checkSpecs[run.id], let probe = layoutProbe else { return }
        checking.insert(run.id)
        defer { checking.remove(run.id) }
        let after = await probe.measure(url: spec.page, widths: spec.widths)
        guard !after.isEmpty else { return }
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
        let composed = message ?? Self.tweakMessage(for: run, change: text)
        lastTweakMessage = composed
        if echo { store.append(.user, text, to: store.conversation(for: .bot(bot.id))) }
        tweakRunId = nil
        if let reason = whyRunCannotStart(run) {
            store.append(.system, "Can't run this yet: \(reason).", to: store.conversation(for: .bot(bot.id)))
            return
        }
        guard store.apply(.tweak, to: run) else { return }
        // darkmux keeps a Tweak's changes together with the run it continues.
        let continues = run.darkmuxWorkId
        _ = startRealRun(run, message: composed, store: store, continues: continues)
    }




    // MARK: Pull requests

    /// Bots with a PR being opened (their button waits).
    var openingPR: Set<UUID> = []

    /// The bot's committed runs not yet in a PR from this thread.
    func unshippedRuns(_ bot: Bot, store: BotStore) -> [BotRun] {
        let lastPR = (store.conversation(for: .bot(bot.id)).messages ?? [])
            .filter { $0.kind == .prCard }.map(\.timestamp).max() ?? .distantPast
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
        openingPR.insert(bot.id)
        defer { openingPR.remove(bot.id) }
        do {
            let changes = try await connection.client.changes(token: darkmux, workspace: workspace)
            guard !changes.files.isEmpty else {
                store.append(.system, "Nothing to open a PR with: \(changes.branch) has no changes against \(changes.baseBranch).", to: thread); return
            }
            let runs = unshippedRuns(bot, store: store)
            let text = PRText.make(bot: bot, runs: runs, machine: FleetConnection.machineName)
            let pr = try await GitHubPR(token: token).open(changes, repo: repo, title: text.title, body: text.body)
            store.append(.system, "Opened PR #\(pr.number): \(pr.url.absoluteString)", kind: .prCard, runId: runs.last?.id, to: thread)
        } catch GitHubPR.Failure.cantWrite(let repo) {
            let install = await github.installState(for: repo)
            if case let .notInstalled(url) = install {
                store.append(.system, "Install Mux Bot on \(repo) to open pull requests: \(url.absoluteString)", to: thread)
            } else {
                store.append(.system, GitHubPR.Failure.cantWrite(repo).localizedDescription, to: thread)
            }
        } catch {
            store.append(.system, "Couldn't open the PR: \(error.localizedDescription)", to: thread)
        }
    }
}
