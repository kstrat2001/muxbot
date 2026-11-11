import SwiftUI
import SwiftData

/// One stage of a run, as a card in the bot's thread: the dispatch
/// proposal, the live run, the result, or the PR question. Buttons show
/// only on the newest card for a stage that is still waiting on you.
struct RunCardView: View {
    let message: ChatMessage
    let isLatest: Bool

    @Environment(\.modelContext) private var context
    @Environment(BotBrain.self) private var brain
    @Environment(AppRouter.self) private var router
    @Environment(FleetConnection.self) private var connection
    @Query private var runs: [BotRun]
    @State private var confirmStop = false

    init(message: ChatMessage, isLatest: Bool) {
        self.message = message
        self.isLatest = isLatest
        let id = message.runId ?? UUID()
        _runs = Query(filter: #Predicate<BotRun> { $0.id == id })
    }

    var body: some View {
        if let run = runs.first {
            CardView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    content(for: run)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .chatColumn(alignment: .leading)
            // A card proposed elsewhere (another device, before a relaunch):
            // its model is chosen here, so Always ask's picker or a missing
            // default model's warning shows before you tap Approve.
            .task(id: run.id) {
                if isLatest, run.phase == .proposed, brain.runs.runChoices[run.id] == nil, brain.runs.choosingModel[run.id] == nil {
                    await brain.runs.chooseProfile(for: run)
                }
            }
        }
    }

    @ViewBuilder private func content(for run: BotRun) -> some View {
        switch message.kind {
        case .dispatchCard:
            Label("Dispatch to \(run.crew.name)", systemImage: run.crew.systemImage).font(AppFont.headline())
            Text(Linkify.attributed(run.task, repo: repo(run))).font(AppFont.body())
            RefChips(refs: refs(run))
            // What the app measured in the preview, in plain sight before Approve.
            let measured = LayoutMeasure.measuredLines(in: run.brief ?? "")
            if !measured.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Label("Measured in the preview", systemImage: "ruler").font(AppFont.footnote(.semibold))
                    ForEach(measured, id: \.self) { line in
                        Text("• \(line)").font(AppFont.footnote()).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            modelRow(run)
            DisclosureGroup("What \(run.crew.name) gets") {
                Text(RunCoordinator.workBrief(run.brief ?? run.task, recipe: run.bot.flatMap(brain.runs.recipes.recipe(for:))))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(AppFont.footnote())
            if run.phase == .proposed {
                if case let .needsWorkCopy(what)? = brain.runs.blocker(for: run), let bot = run.bot {
                    workCopyAsk(what, bot: bot, run: run)
                } else if case .projectNotMade(_, here: true)? = brain.runs.blocker(for: run), let bot = run.bot {
                    projectAsk(bot: bot, run: run)
                } else if let reason = brain.runs.whyRunCannotStart(run) {
                    Text("Can't run yet: \(reason).").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                    HStack {
                        Button("Cancel") { brain.runs.decide(.cancel, on: run, store: store) }.buttonStyle(.bordered)
                        Spacer()
                        #if os(macOS)
                        if connection.isPaired == false {
                            Button("Pair with darkmux", systemImage: "link") { router.showPairing = true }
                                .buttonStyle(.borderedProminent).tint(Color.brandGreen)
                        }
                        #endif
                    }
                } else {
                    buttons([("Cancel", .cancel, false), ("Approve", .approve, true)], run: run)
                }
            } else {
                outcome(run.phase == .canceled ? .failed : .done)
            }
        case .runCard:
            HStack(spacing: Spacing.sm) {
                StatusBadge(kind: isLatest && run.phase == .running ? .running : run.phase == .canceled ? .failed : .done)
                Label(run.crew.name, systemImage: run.crew.systemImage).font(AppFont.headline())
                Spacer()
                if isLatest && run.phase == .running {
                    Button("Stop this run", systemImage: "stop.circle") { confirmStop = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Stop this run")
                        .confirmationDialog("Stop this run?", isPresented: $confirmStop) {
                            Button("Stop", role: .destructive) { Task { await brain.runs.stop(run, store: store) } }
                            Button("Keep running", role: .cancel) {}
                        }
                }
                if let bot = run.bot, brain.runs.canPreview(bot) {
                    Button("Live", systemImage: "play.rectangle") { router.showPreview = true }
                }
            }
            if isLatest && brain.runs.unreachableRuns.contains(run.id) {
                Label("Can't reach darkmux on this Mac. Still trying…", systemImage: "wifi.exclamationmark")
                    .font(AppFont.footnote()).labelStyle(.tintedIcon(Color.brandOrange))
            } else if isLatest, run.phase == .running, let activity = brain.runs.runActivity[run.id] {
                // The model is loading, or busy with another run: said, so a
                // slow start doesn't look stuck.
                Label(activity.line, systemImage: activity == .queued ? "hourglass" : "cpu")
                    .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            }
            Text(Linkify.attributed(message.content, repo: repo(run))).font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            leftBehindUndo(run)
        case .resultCard:
            if let line = RunCardState.collapsedLine(run) {
                Label(line, systemImage: run.phase == .discarded ? "arrow.uturn.backward" : "checkmark.circle")
                    .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            } else if RunCardState.isReplaced(run) {
                Label("Replaced by the next run", systemImage: "arrow.turn.down.right")
                    .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            } else if run.phase == .result && run.changedFiles.isEmpty && run.crew.changesFiles {
                questionCard(run)
            } else {
                resultCard(run)
            }
        case .prCard where message.content.hasPrefix("Opened PR"):
            Label("Pull request opened", systemImage: "arrow.triangle.pull").font(AppFont.headline())
            Text(Linkify.attributed(message.content, repo: repo(run))).font(AppFont.body())
        case .prCard:
            Label("Pull request", systemImage: "arrow.triangle.pull").font(AppFont.headline())
            RefChips(refs: refs(run))
            switch run.phase {
            case .kept:
                // Earlier builds' Keep: moved to a committed result at launch
                // (BotStore.migrateKeptRuns), so Open PR includes it.
                Text("Committed. Open a pull request from the thread's Open PR.").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            case .prOpened:
                // Older builds showed a placeholder here; nothing was opened.
                Text("Not opened.")
                    .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            default:
                Text("No pull request.").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            }
        case .text, .bugCard, .actionCard, .guideCard:
            EmptyView()
        }
    }

    /// A finished run: summary, diff, notes, Keep / Tweak / Discard.
    @ViewBuilder private func resultCard(_ run: BotRun) -> some View {
        RefChips(refs: refs(run))
        if run.phase == .failed || (run.phase == .canceled && message.content.hasPrefix("darkmux reported")) {
            Label(run.phase == .failed ? run.summary : "Stopped",
                  systemImage: run.phase == .failed ? "exclamationmark.triangle" : "stop.circle")
                .font(AppFont.body())
            if let details = run.details, !details.isEmpty {
                DisclosureGroup("Details") {
                    Text(details)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(AppFont.footnote())
            }
        } else {
            // The bot's reply: what changed, in plain words. darkmux already
            // committed it to the bot's branch.
            Text(Linkify.attributed(message.content, repo: repo(run), linkPaths: true)).font(AppFont.body())
            doneWhenCheck(run)
            HStack(spacing: Spacing.md) {
                if let bot = run.bot, brain.runs.canPreview(bot) {
                    Button("See it in the preview", systemImage: "play.rectangle") { router.showPreview = true }
                        .buttonStyle(.borderless)
                }
                // The PR this run went into, once one is open.
                if let pr = prURL(after: run) {
                    Link(destination: pr) { Label("PR #\(pr.lastPathComponent)", systemImage: "arrow.triangle.pull") }
                        .buttonStyle(.borderless)
                }
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if let model = brain.runs.modelLine(for: run) {
                        Text("Ran on \(model)").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                    }
                    if let branch = run.keptBranch, let commit = run.keptCommit {
                        Text("Committed to \(branch) (\(commit))").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                    }
                    // A commit error always shows, even with an older commit's branch.
                    if let why = run.details {
                        Label(why, systemImage: "exclamationmark.triangle").font(AppFont.footnote())
                    }
                    Label(run.changedFiles.joined(separator: "\n"), systemImage: "doc.text").font(AppFont.footnote())
                    DiffView(diff: run.diff ?? "No diff available.")
                    if let notes = run.notes {
                        Text(Linkify.apply(to: (try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(notes),
                                           repo: repo(run), linkPaths: true))
                            .font(AppFont.footnote())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(AppFont.footnote())
            if let problem = RunCardState.checkpointProblem(run) {
                // darkmux couldn't commit the changes: they're in the work copy,
                // but there's no checkpoint to undo.
                Label("The checkpoint didn't happen: \(problem) The changes are in the work copy, uncommitted.",
                      systemImage: "exclamationmark.triangle")
                    .font(AppFont.footnote()).labelStyle(.tintedIcon(Color.brandOrange))
            }
            if isLatest && run.phase == .result {
                HStack {
                    Text("Reply to change it.").font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                    Spacer()
                    if brain.runs.deciding.contains(run.id) { ProgressView().controlSize(.small) }
                    if RunCardState.canUndo(run) {
                        Button("Undo", systemImage: "arrow.uturn.backward") { brain.runs.decide(.discard, on: run, store: store) }
                            .buttonStyle(.bordered)
                            .disabled(brain.runs.deciding.contains(run.id))
                            .help("Revert this run's commit")
                    } else if RunCardState.canClose(run) {
                        Button(run.crew.changesFiles ? "Close" : "Done") { brain.runs.decide(.close, on: run, store: store) }.buttonStyle(.bordered)
                    }
                }
            }
        }
        leftBehindUndo(run)
        decisionError(run)
    }

    /// A finished run that changed nothing (it stopped to ask): its question,
    /// one-tap answers for numbered options (sent as a Tweak), a free answer,
    /// and Close. Never Keep or Discard: there's nothing to keep.
    @ViewBuilder private func questionCard(_ run: BotRun) -> some View {
        RefChips(refs: refs(run))
        if let claim = RunResultText.unbackedClaim(in: [run.notes ?? "", run.summary], crew: run.crew.name, changedFiles: run.changedFiles) {
            // Its words say it edited something; darkmux saw no change.
            Label(claim, systemImage: "exclamationmark.triangle")
                .font(AppFont.headline()).labelStyle(.tintedIcon(Color.brandOrange))
        } else {
            Label("\(run.crew.name) changed nothing and has a question", systemImage: "questionmark.bubble")
                .font(AppFont.headline())
        }
        if let notes = run.notes {
            Text(Linkify.apply(to: (try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(notes),
                               repo: repo(run), linkPaths: true))
                .font(AppFont.body())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(message.content).font(AppFont.body())
        }
        if isLatest {
            let options = AgentQuestion.options(in: run.notes ?? "")
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button { brain.runs.tweak("Go with option \(index + 1): \(option)", run: run, store: store) } label: {
                    Text("\(index + 1). \(option)").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Text(options.isEmpty ? "Reply to answer." : "Tap an answer, or reply in your own words.")
                    .font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                Spacer()
                Button("Close") { brain.runs.decide(.close, on: run, store: store) }.buttonStyle(.bordered)
            }
            decisionError(run)
        }
    }

    /// Always ask: a picker before Approve. A chosen model that isn't running:
    /// said, with Auto's pick offered (never swapped silently).
    @ViewBuilder private func modelRow(_ run: BotRun) -> some View {
        if run.phase == .proposed, brain.runs.choosingModel[run.id] != nil {
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Choosing the model…").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            }
        } else if run.phase == .proposed, let choice = brain.runs.runChoices[run.id] {
            ModelPickRow(choice: choice, current: brain.runs.profile(for: run), options: brain.runs.choices(for: run),
                         line: { brain.runs.modelLine($0, for: run) }, pick: { brain.runs.override(run, with: $0) })
        }
    }

    /// The done-when, measured in the preview after the run.
    @ViewBuilder private func doneWhenCheck(_ run: BotRun) -> some View {
        if brain.runs.checking.contains(run.id) {
            Label("Checking the done-when in the preview…", systemImage: "ruler")
                .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
        } else if brain.runs.runChecks[run.id] == nil, let problem = brain.runs.checkProblems[run.id] {
            // Never silent: it checks by itself once the preview is running.
            HStack {
                Label(problem, systemImage: "ruler").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                Spacer()
                Button("Check again") { Task { await brain.runs.check(run) } }.buttonStyle(.bordered)
            }
        } else if let check = brain.runs.runChecks[run.id] {
            if check.met {
                Label("Done when: met (measured in the preview)", systemImage: "checkmark.seal.fill")
                    .font(AppFont.footnote(.semibold)).labelStyle(.tintedIcon(Color.brandGreen))
            } else {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Label("Done when: not met", systemImage: "xmark.seal.fill")
                        .font(AppFont.footnote(.semibold)).labelStyle(.tintedIcon(Color.brandOrange))
                    ForEach(check.failures, id: \.self) { Text("• \($0)").font(AppFont.footnote()).textSelection(.enabled) }
                    if isLatest {
                        HStack {
                            Button("Run again with these numbers", systemImage: "arrow.clockwise") {
                                Task { await brain.rerun(run, change: LayoutCheck.rerunChange(check), store: store, nextModel: true) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(brain.runs.rerunning.contains(run.id))
                            if brain.runs.rerunning.contains(run.id) { ProgressView().controlSize(.small) }
                            // A default model stays on its model; offer the next one.
                            if let next = brain.runs.runChoices[run.id]?.offerNext {
                                Button("Run again on \(next)") {
                                    Task { await brain.rerun(run, change: LayoutCheck.rerunChange(check), store: store, model: next) }
                                }
                                .disabled(brain.runs.rerunning.contains(run.id))
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A stopped or failed run that left a commit behind: Undo puts it back.
    @ViewBuilder private func leftBehindUndo(_ run: BotRun) -> some View {
        if isLatest, run.phase == .failed || run.phase == .canceled, RunCardState.canUndo(run) {
            Button("Undo", systemImage: "arrow.uturn.backward") { brain.runs.decide(.discard, on: run, store: store) }
                .buttonStyle(.bordered)
                .disabled(brain.runs.deciding.contains(run.id))
        }
    }

    @ViewBuilder private func decisionError(_ run: BotRun) -> some View {
        if let why = brain.runs.decisionErrors[run.id] {
            Label(why, systemImage: "exclamationmark.triangle").font(AppFont.footnote()).labelStyle(.tintedIcon(Color.brandOrange))
            if let details = brain.runs.decisionDetails[run.id] { TechnicalDetails(text: details) }
        }
    }

    private var store: BotStore { BotStore(context: context) }

    /// A PR opened in this thread after the run finished (so it carries it).
    private func prURL(after run: BotRun) -> URL? {
        let done = run.finishedAt ?? run.createdAt
        let later = (message.conversation?.messages ?? []).filter { $0.kind == .prCard && $0.timestamp >= done }
        return PRLinks.latest(in: later)
    }

    /// The bot has code but no work copy on this Mac: offer to set one up
    /// (Approve), then the card becomes the usual dispatch card.
    @ViewBuilder private func workCopyAsk(_ what: String, bot: Bot, run: BotRun) -> some View {
        let machine = FleetConnection.machineName
        switch brain.runs.workCopySetup[bot.id] {
        case .settingUp?:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Setting up \(what) on \(machine)…").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            }
        case let .failed(why)?:
            Label("Couldn't set up \(what) on this Mac. Try again.", systemImage: "exclamationmark.triangle").font(AppFont.footnote())
            // darkmux's own words, for bug reports.
            TechnicalDetails(text: why)
            buttonsForSetup(bot: bot, run: run, retry: true)
        case nil:
            Text("Set up \(what) on \(machine)? darkmux makes its own copy on a new branch, so your files aren't touched.")
                .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            buttonsForSetup(bot: bot, run: run, retry: false)
        }
    }

    /// A template bot whose project isn't on this Mac yet (it was made while
    /// unpaired, or on iPhone): make it here from its template.
    @ViewBuilder private func projectAsk(bot: Bot, run: BotRun) -> some View {
        switch brain.runs.workCopySetup[bot.id] {
        case .settingUp?:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Making \(bot.name)'s project on this Mac…").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            }
        case let .failed(why)?:
            Label("Couldn't make \(bot.name)'s project on this Mac. Try again.", systemImage: "exclamationmark.triangle").font(AppFont.footnote())
            TechnicalDetails(text: why)
            buttonsForProject(bot: bot, run: run, retry: true)
        case nil:
            Text("\(bot.name)'s project isn't on this Mac yet. Make it now? darkmux makes a fresh copy of its template here, then this run can start.")
                .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
            buttonsForProject(bot: bot, run: run, retry: false)
        }
    }

    private func buttonsForProject(bot: Bot, run: BotRun, retry: Bool) -> some View {
        HStack {
            Button("Cancel") { brain.runs.decide(.cancel, on: run, store: store) }.buttonStyle(.bordered)
            Spacer()
            Button(retry ? "Try again" : "Make the project") {
                Task {
                    await brain.runs.setUpWorkCopy(for: bot, store: store)
                    if bot.workspaceName != nil { await brain.runs.ensurePreview(for: bot) }
                }
            }
            .buttonStyle(.borderedProminent).tint(Color.brandGreen)
        }
    }

    private func buttonsForSetup(bot: Bot, run: BotRun, retry: Bool) -> some View {
        HStack {
            Button("Cancel") { brain.runs.decide(.cancel, on: run, store: store) }.buttonStyle(.bordered)
            Spacer()
            Button(retry ? "Try again" : "Approve") { Task { await brain.runs.setUpWorkCopy(for: bot, store: store) } }
                .buttonStyle(.borderedProminent).tint(Color.brandGreen)
        }
    }

    private func repo(_ run: BotRun) -> String? { run.bot?.repoSlugs.first }

    /// The issues and PRs the run's task and brief mention.
    private func refs(_ run: BotRun) -> [GitHubRef] {
        Linkify.references(in: [run.task, run.brief ?? ""].joined(separator: "\n"), repo: repo(run))
    }

    private func buttons(_ items: [(String, RunEvent, Bool)], run: BotRun) -> some View {
        HStack {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index == items.count - 1 { Spacer() }
                if item.2 {
                    Button(item.0) { brain.runs.decide(item.1, on: run, store: store) }.buttonStyle(.borderedProminent).tint(Color.brandGreen)
                } else {
                    Button(item.0) { brain.runs.decide(item.1, on: run, store: store) }.buttonStyle(.bordered)
                }
            }
        }
    }

    private func outcome(_ kind: StatusKind) -> some View {
        StatusBadge(kind: kind)
    }
}

/// Small tappable chips for the issues and PRs a card mentions ("hcr#8").
/// They open GitHub in the default browser.
struct RefChips: View {
    let refs: [GitHubRef]

    var body: some View {
        if !refs.isEmpty {
            HStack(spacing: Spacing.xs) {
                ForEach(refs, id: \.self) { ref in
                    Link(destination: ref.url) {
                        Text(ref.label)
                            .font(AppFont.footnote(.semibold))
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .help(ref.url.absoluteString)
                    .accessibilityLabel("Open \(ref.label) on GitHub")
                }
            }
        }
    }
}

/// A unified diff with added lines green, removed red, hunks blue.
struct DiffView: View {
    let diff: String

    var body: some View {
        Text(colored)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var colored: AttributedString {
        var out = AttributedString()
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            var piece = AttributedString(String(line) + "\n")
            switch DiffLine.kind(of: String(line)) {
            case .added: piece.foregroundColor = .green; piece.backgroundColor = Color.green.opacity(0.08)
            case .removed: piece.foregroundColor = .red; piece.backgroundColor = Color.red.opacity(0.08)
            case .hunk: piece.foregroundColor = .blue
            case .meta: piece.foregroundColor = .secondary
            case .context: break
            }
            out += piece
        }
        return out
    }
}

/// The model a run will use, before it starts: the dispatch card's row and
/// the bug card's beside Fix it now. Always ask is a picker; otherwise the
/// model and engine with a one-run Change; a chosen model that isn't running
/// is said, with Auto's pick offered (never swapped silently).
struct ModelPickRow: View {
    let choice: ModelChoice
    /// The profile picked now (nil: darkmux picks).
    let current: String?
    let options: [DarkmuxClient.ProfileInfo]
    /// A profile as people see it ("model · engine").
    let line: (String) -> String
    let pick: (String) -> Void

    var body: some View {
        if let why = choice.unavailable, current == choice.profile {
            HStack {
                Label(why, systemImage: "exclamationmark.triangle").font(AppFont.footnote()).labelStyle(.tintedIcon(Color.brandOrange))
                Spacer()
                if let other = choice.suggestion {
                    Button("Use \(line(other)) for this run") { pick(other) }.buttonStyle(.bordered)
                }
            }
        } else if choice.ask {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Picker("Model", selection: Binding(get: { current ?? "" }, set: { pick($0) })) {
                    ForEach(options, id: \.name) { Text(ModelLabel.line($0)).tag($0.name) }
                    // The pick is kept even when it's a duplicate the list folded away.
                    if let current, !options.contains(where: { $0.name == current }) {
                        Text(line(current)).tag(current)
                    }
                }
                Text(choice.reason).font(AppFont.caption()).foregroundStyle(Color.secondaryText)
            }
        } else if let current {
            // The model and engine this run will use, with Change for this run only.
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(line(current), systemImage: "cpu").font(AppFont.footnote(.semibold))
                    Text(current == choice.profile ? choice.reason : String(localized: "chosen for this run"))
                        .font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                }
                Spacer()
                if !options.isEmpty {
                    Menu("Change") {
                        ForEach(options, id: \.name) { p in
                            Button(ModelLabel.line(p)) { pick(p.name) }
                        }
                    }
                    .fixedSize()
                }
            }
        } else {
            Label(String(choice.reason.prefix(1).uppercased() + choice.reason.dropFirst()), systemImage: "cpu")
                .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
        }
    }
}
