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
        }
    }

    @ViewBuilder private func content(for run: BotRun) -> some View {
        switch message.kind {
        case .dispatchCard:
            Label("Dispatch to \(run.crew.name)", systemImage: run.crew.systemImage).font(AppFont.headline())
            Text(Linkify.attributed(run.task, repo: repo(run))).font(AppFont.body())
            RefChips(refs: refs(run))
            DisclosureGroup("What \(run.crew.name) gets") {
                Text(BotBrain.workBrief(run.brief ?? run.task, recipe: run.bot.flatMap(brain.recipe(for:))))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(AppFont.footnote())
            if run.phase == .proposed {
                if let reason = brain.whyRunCannotStart(run) {
                    Text("Can't run yet: \(reason).").font(AppFont.footnote()).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { brain.decide(.cancel, on: run, store: store) }.buttonStyle(.bordered)
                        Spacer()
                        #if os(macOS)
                        if connection.isPaired == false {
                            Button("Pair with darkmux", systemImage: "link") { router.showPairing = true }
                                .buttonStyle(.borderedProminent)
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
                            Button("Stop", role: .destructive) { Task { await brain.stop(run, store: store) } }
                            Button("Keep running", role: .cancel) {}
                        }
                }
                if run.bot?.previewURL != nil {
                    Button("Live", systemImage: "play.rectangle") { router.showPreview = true }
                }
            }
            Text(Linkify.attributed(message.content, repo: repo(run))).font(AppFont.footnote()).foregroundStyle(.secondary)
        case .resultCard:
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
                Text(Linkify.attributed(message.content, repo: repo(run), linkPaths: true)).font(AppFont.body())
                if !run.changedFiles.isEmpty {
                    DisclosureGroup {
                        Text(run.diff ?? "No diff available.")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label(run.changedFiles.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "), systemImage: "doc.text")
                            .font(AppFont.footnote(.semibold))
                    }
                }
                if let notes = run.notes {
                    DisclosureGroup("\(run.crew.name)'s notes") {
                        Text(Linkify.apply(to: (try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(notes),
                                           repo: repo(run), linkPaths: true))
                            .font(AppFont.footnote())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(AppFont.footnote())
                }
                if isLatest && run.phase == .result {
                    HStack {
                        Button("Discard", systemImage: "trash", role: .destructive) { brain.decide(.discard, on: run, store: store) }
                            .buttonStyle(.bordered)
                        Button("Tweak", systemImage: "pencil") {
                            brain.tweakRunId = run.id
                            router.barDraft = ""
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("Keep", systemImage: "checkmark") { brain.decide(.keep, on: run, store: store) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    outcome(isLatest && run.phase == .discarded ? .failed : .done)
                }
            }
        case .prCard:
            Label("Pull request", systemImage: "arrow.triangle.pull").font(AppFont.headline())
            RefChips(refs: refs(run))
            switch run.phase {
            case .kept:
                Text(RunResultText.prUnavailable).font(AppFont.footnote()).foregroundStyle(.secondary)
                HStack {
                    Button("Not now") { brain.decide(.skipPR, on: run, store: store) }.buttonStyle(.bordered)
                    Spacer()
                    Button("Pass to \(LeadBot.name)") { brain.passPRToLead(run, store: store) }.buttonStyle(.borderedProminent)
                }
            case .prOpened:
                // Older builds showed a placeholder here; nothing was opened.
                Text("Not opened.")
                    .font(AppFont.footnote()).foregroundStyle(.secondary)
            default:
                Text("No pull request.").font(AppFont.footnote()).foregroundStyle(.secondary)
            }
        case .text, .bugCard, .actionCard:
            EmptyView()
        }
    }

    private var store: BotStore { BotStore(context: context) }

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
                    Button(item.0) { brain.decide(item.1, on: run, store: store) }.buttonStyle(.borderedProminent)
                } else {
                    Button(item.0) { brain.decide(item.1, on: run, store: store) }.buttonStyle(.bordered)
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
