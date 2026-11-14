import SwiftUI
import SwiftData

/// Start review (in place of Open PR): an editable title, the changes it
/// includes, and who reviews it. The pull request is opened first, then the
/// review you picked starts.
struct StartReviewSheet: View {
    let bot: Bot

    @Environment(BotBrain.self) private var brain
    @Environment(GitHubAuth.self) private var github
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var byReviewer = true

    private var store: BotStore { BotStore(context: modelContext) }
    private var runs: [BotRun] { brain.runs.unshippedRuns(bot, store: store) }
    private var fileCount: Int {
        Set(runs.flatMap { $0.changedFiles.map { $0.components(separatedBy: " +").first ?? $0 } }).count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                } footer: {
                    Text(runs.count == 1 ? "1 change" : "\(runs.count) changes")
                        + Text(fileCount > 0 ? (fileCount == 1 ? " · 1 file" : " · \(fileCount) files") : "")
                }
                Section("Changes") {
                    DisclosureGroup("Show changes") {
                        ForEach(runs) { run in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.task).font(AppFont.body())
                                if !run.summary.isEmpty {
                                    Text(run.summary).font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                                }
                            }
                        }
                    }
                }
                Section {
                    choice(true, "Reviewer checks it first", "Runs on this Mac. You get a short list of things to look at.")
                    choice(false, "I'll review it myself", "Look at the preview and the changes, then merge.")
                } footer: {
                    Text("This opens a pull request on GitHub: the page where a change is checked before it joins your project.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Start review")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start review") {
                        let bot = bot, title = title, byReviewer = byReviewer, store = store
                        dismiss()
                        Task { await brain.runs.startReview(for: bot, title: title, byReviewer: byReviewer, store: store, github: github) }
                    }
                    .disabled(runs.isEmpty)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
        .onAppear {
            if title.isEmpty { title = PRText.make(bot: bot, runs: runs, machine: FleetConnection.machineName).title }
        }
    }

    private func choice(_ value: Bool, _ label: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        Button { byReviewer = value } label: {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: byReviewer == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(byReviewer == value ? Color.brandGreen : Color.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(AppFont.body(.semibold))
                    Text(detail).font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(byReviewer == value ? .isSelected : [])
    }
}

/// The task's review, pinned at the top of its thread: the Reviewer's list
/// (each item with Fix this), where it stands on GitHub, and Merge when
/// GitHub says it can go in. The list stays in the app.
struct ReviewCardView: View {
    let bot: Bot

    @Environment(BotBrain.self) private var brain
    @Environment(GitHubAuth.self) private var github
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    /// Items sent to the Coder from this card (this view's lifetime).
    @State private var sent: Set<Int> = []
    @State private var sentAll = false
    @State private var expanded = true

    private var store: BotStore { BotStore(context: modelContext) }

    var body: some View {
        if let state = brain.runs.review(for: bot) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Label("In review", systemImage: "checkmark.bubble").font(AppFont.subheadline(.semibold))
                    if let tag = tag(state) {
                        Text(tag).font(AppFont.caption(.semibold)).foregroundStyle(Color.secondaryText)
                    }
                    Spacer(minLength: 0)
                    Button(expanded ? "Hide" : "Show", systemImage: expanded ? "chevron.up" : "chevron.down") { expanded.toggle() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                if expanded {
                    Text(state.title).font(AppFont.footnote()).foregroundStyle(Color.secondaryText).lineLimit(2)
                    stepRow(state)
                    reviewer(state)
                    if let sentence = standing?.sentence {
                        Text(sentence).font(AppFont.footnote())
                    }
                    actions(state)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(.bar)
            // Again when the Reviewer finishes: GitHub may have settled by then.
            .task(id: "\(state.number)-\(reviewerFinished(state))") { await brain.runs.followReview(bot, store: store, github: github) }
        }
    }

    private var standing: TaskReview.Standing? { brain.runs.reviewStandings[bot.id] }

    private func reviewerFinished(_ state: TaskReview.State) -> Bool {
        guard let phase = reviewerRun(state)?.phase else { return false }
        return [.result, .failed, .canceled, .discarded].contains(phase)
    }

    /// Opened → checked → merge, so you can see where the review is.
    private func stepRow(_ state: TaskReview.State) -> some View {
        let steps = TaskReview.steps(state, reviewerFinished: reviewerFinished(state), standing: standing)
        return HStack(spacing: Spacing.sm) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { Image(systemName: "chevron.right").font(AppFont.caption()).foregroundStyle(Color.secondaryText) }
                Label(step.title, systemImage: step.state == .done ? "checkmark.circle.fill" : step.state == .now ? "circle.inset.filled" : "circle")
                    .font(AppFont.caption(step.state == .now ? .semibold : .regular))
                    .foregroundStyle(step.state == .later ? Color.secondaryText : Color.primary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func reviewerRun(_ state: TaskReview.State) -> BotRun? {
        state.reviewerRun.flatMap(UUID.init(uuidString:)).flatMap(store.run(id:))
    }

    private func tag(_ state: TaskReview.State) -> String? {
        if state.mine { return String(localized: "Your review") }
        guard let items = state.items else { return state.raw != nil ? String(localized: "Reviewer answered") : nil }
        return items.isEmpty ? String(localized: "Reviewer found nothing to change")
            : items.count == 1 ? String(localized: "Reviewer found 1 thing") : String(localized: "Reviewer found \(items.count) things")
    }

    @ViewBuilder private func reviewer(_ state: TaskReview.State) -> some View {
        if state.mine {
            Text("Look at the preview and the changes, then merge.").font(AppFont.footnote())
        } else if let items = state.items, !items.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                            Text("\(index + 1). \(item)").font(AppFont.footnote()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(sent.contains(index) ? "Sent" : "Fix this") {
                                let run = brain.runs.proposeFix(item, all: false, bot: bot, store: store)
                                sent.insert(index)
                                router.focusRunId = run.id
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(sent.contains(index))
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
            disclaimer
        } else if let raw = state.raw {
            ScrollView {
                Text(raw).font(AppFont.footnote()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            Button(sentAll ? "Sent" : "Fix these") {
                let run = brain.runs.proposeFix(raw, all: true, bot: bot, store: store)
                sentAll = true
                router.focusRunId = run.id
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(sentAll)
            disclaimer
        } else if state.items != nil {
            EmptyView()   // nothing to change: the tag says so
        } else if let run = reviewerRun(state) {
            switch run.phase {
            case .proposed:
                Button("The Reviewer's card is waiting for your Approve.") { router.focusRunId = run.id }
                    .buttonStyle(.plain).font(AppFont.footnote())
            case .failed, .canceled, .discarded:
                Text("The Reviewer didn't finish. You can review it yourself, then merge.").font(AppFont.footnote())
            case .running:
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("The Reviewer is checking it.").font(AppFont.footnote())
                }
            default:
                Text("The Reviewer gave no answer. You can review it yourself, then merge.").font(AppFont.footnote())
            }
        }
    }

    private var disclaimer: some View {
        Text("A local model wrote this list. It can miss things or be wrong.")
            .font(AppFont.caption()).foregroundStyle(Color.secondaryText)
    }

    @ViewBuilder private func actions(_ state: TaskReview.State) -> some View {
        HStack(spacing: Spacing.sm) {
            if standing == .ready {
                if brain.runs.merging.contains(bot.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Merge", systemImage: "arrow.triangle.merge") {
                        Task { await brain.runs.mergeReview(bot, store: store, github: github) }
                    }
                    .buttonStyle(.borderedProminent).tint(Color.brandGreen)
                    .disabled(reviewerRun(state)?.phase == .running)
                }
            }
            Button("See it on GitHub", systemImage: "arrow.up.forward.square") { openURL(state.url) }
                .buttonStyle(.bordered)
            if standing != .ready {
                Button("Check again", systemImage: "arrow.clockwise") {
                    Task { await brain.runs.refreshReview(bot, store: store, github: github) }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Check again with GitHub")
            }
        }
        .controlSize(.small)
    }
}
