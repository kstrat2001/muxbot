import SwiftUI
import SwiftData

/// The task's saved changes that aren't in a review yet, as numbers.
enum PendingChanges {
    struct Totals: Equatable {
        var changes = 0
        var files = 0
        var added = 0
        var removed = 0
    }

    struct FileLine: Equatable {
        var path: String
        var added = 0
        var removed = 0
    }

    /// A run keeps each changed file as "path +N −M"; a hand edit keeps
    /// only the path.
    static func parse(_ entry: String) -> FileLine {
        let parts = entry.split(separator: " ")
        guard parts.count >= 3,
              let plus = parts[parts.count - 2].first, plus == "+",
              let added = Int(parts[parts.count - 2].dropFirst()),
              let minus = parts[parts.count - 1].first, minus == "−" || minus == "-",
              let removed = Int(parts[parts.count - 1].dropFirst()) else { return FileLine(path: entry) }
        return FileLine(path: parts.dropLast(2).joined(separator: " "), added: added, removed: removed)
    }

    /// One entry per change, each its changed files. A file changed twice
    /// counts once as a file and both times as lines.
    static func totals(_ changes: [[String]]) -> Totals {
        let lines = changes.flatMap { $0.map(parse) }
        return Totals(changes: changes.count, files: Set(lines.map(\.path)).count,
                      added: lines.reduce(0) { $0 + $1.added }, removed: lines.reduce(0) { $0 + $1.removed })
    }
}

/// The tool shelf directly above the chat bar: the Preview toggle, and the
/// task's pending changes (how many, files, lines added and removed) with
/// See changes, Undo and Review & merge; once a review is open, the review
/// itself with Merge sits on top of the shelf.
struct TaskStatusLine: View {
    let bot: Bot
    /// Review & merge: the sheet, or a line in the thread saying why not yet.
    var startReview: () -> Void

    @Environment(BotBrain.self) private var brain
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @State private var showingChanges = false

    private var store: BotStore { BotStore(context: modelContext) }

    var body: some View {
        let inReview = brain.runs.review(for: bot) != nil
        let canPreview = brain.runs.canPreview(bot)
        let showsChanges = !inReview && bot.workspaceName != nil
        VStack(spacing: 0) {
            if inReview { ReviewCardView(bot: bot) }
            if canPreview || showsChanges {
                HStack(spacing: Spacing.sm) {
                    if canPreview { previewToggle }
                    if showsChanges { pending } else { Spacer(minLength: 0) }
                }
                .font(AppFont.footnote())
                .controlSize(.small)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(.bar)
            }
        }
    }

    /// The toggle's highlight shows the preview is open.
    private var previewToggle: some View {
        @Bindable var router = self.router
        return Toggle(isOn: $router.showPreview) {
            Label("Preview", systemImage: "play.rectangle")
        }
        .toggleStyle(.button)
        .help(router.showPreview ? "Hide preview" : "Show preview")
    }

    @ViewBuilder private var pending: some View {
        let runs = brain.runs.unshippedRuns(bot, store: store)
        if runs.isEmpty {
            Label("No pending changes", systemImage: "checkmark.circle")
                .foregroundStyle(Color.secondaryText)
            Spacer(minLength: 0)
        } else {
            summary(PendingChanges.totals(runs.map(\.changedFiles)))
            Spacer(minLength: 0)
            Button("See changes") { showingChanges = true }
                .buttonStyle(.bordered)
                .popover(isPresented: $showingChanges) { PendingChangesList(bot: bot) }
            if let last = AppAction.lastUndoable(bot), runs.contains(where: { $0.id == last.id }) {
                Button("Undo", systemImage: "arrow.uturn.backward") { brain.runs.decide(.discard, on: last, store: store) }
                    .buttonStyle(.bordered)
                    .disabled(brain.runs.deciding.contains(last.id))
                    .help("Take back the latest change")
            }
            if brain.runs.openingPR.contains(bot.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Review & merge", systemImage: "checkmark.bubble", action: startReview)
                    .buttonStyle(.borderedProminent).tint(Color.brandGreen)
                    .help("Review this task's saved changes, then merge them into the project")
            }
        }
    }

    private func summary(_ totals: PendingChanges.Totals) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(totals.changes == 1 ? "1 change" : "\(totals.changes) changes").font(AppFont.footnote(.semibold))
            if totals.files > 0 {
                Text(totals.files == 1 ? "1 file" : "\(totals.files) files").foregroundStyle(Color.secondaryText)
            }
            if totals.added + totals.removed > 0 {
                Text(verbatim: "+\(totals.added)").foregroundStyle(Color.brandGreen)
                Text(verbatim: "−\(totals.removed)").foregroundStyle(Color.brandRed)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(totals.changes) pending changes in \(totals.files) files, \(totals.added) lines added, \(totals.removed) removed")
    }
}

/// See changes: each saved change with its files and lines, newest first,
/// and Undo where darkmux can still take it back.
struct PendingChangesList: View {
    let bot: Bot

    @Environment(BotBrain.self) private var brain
    @Environment(\.modelContext) private var modelContext

    private var store: BotStore { BotStore(context: modelContext) }

    var body: some View {
        let runs = brain.runs.unshippedRuns(bot, store: store).reversed()
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(Array(runs)) { run in
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.task).font(AppFont.body(.semibold)).lineLimit(2)
                            ForEach(run.changedFiles.map(PendingChanges.parse), id: \.path) { file in
                                HStack(spacing: Spacing.sm) {
                                    Text(file.path).foregroundStyle(Color.secondaryText).lineLimit(1).truncationMode(.middle)
                                    if file.added + file.removed > 0 {
                                        Text(verbatim: "+\(file.added)").foregroundStyle(Color.brandGreen)
                                        Text(verbatim: "−\(file.removed)").foregroundStyle(Color.brandRed)
                                    }
                                }
                                .font(AppFont.caption()).monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if RunCardState.canUndo(run), run.startedHere {
                            Button("Undo") { brain.runs.decide(.discard, on: run, store: store) }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(brain.runs.deciding.contains(run.id))
                        }
                    }
                }
            }
            .padding(Spacing.md)
        }
        .frame(minWidth: 340, idealWidth: 400, maxHeight: 420)
    }
}
