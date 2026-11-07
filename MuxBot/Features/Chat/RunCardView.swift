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
    @Query private var runs: [BotRun]

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
            Text(run.task).font(AppFont.body())
            if run.phase == .proposed {
                buttons([("Cancel", .cancel, false), ("Approve", .approve, true)], run: run)
            } else {
                outcome(run.phase == .canceled ? .failed : .done)
            }
        case .runCard:
            HStack(spacing: Spacing.sm) {
                StatusBadge(kind: isLatest && run.phase == .running ? .running : .done)
                Label(run.crew.name, systemImage: run.crew.systemImage).font(AppFont.headline())
                Spacer()
                if run.previewURL.flatMap(URL.init(string:)) != nil {
                    Button("Live", systemImage: "play.rectangle") { router.showPreview = true }
                } else {
                    Button("Live", systemImage: "play.rectangle") {}
                        .disabled(true)
                        .accessibilityHint("The live preview appears once the fleet is connected.")
                }
            }
            Text(message.content).font(AppFont.footnote()).foregroundStyle(.secondary)
        case .resultCard:
            Text(message.content).font(AppFont.body())
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Color.elevatedBackground)
                .frame(height: 120)
                .overlay {
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Screenshot placeholder")
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
        case .prCard:
            Label("Open a pull request?", systemImage: "arrow.triangle.pull").font(AppFont.headline())
            switch run.phase {
            case .kept:
                buttons([("Not now", .skipPR, false), ("Approve", .openPR, true)], run: run)
            case .prOpened:
                Text("PR opened (sample: the fleet isn't connected yet).").font(AppFont.footnote()).foregroundStyle(.secondary)
            default:
                outcome(.done)
            }
        case .text, .bugCard:
            EmptyView()
        }
    }

    private var store: BotStore { BotStore(context: context) }

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
