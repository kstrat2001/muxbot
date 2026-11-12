import SwiftUI
import SwiftData

/// A drafted bug: what you described, measured page facts, and two ways
/// forward: change it now in the bot's task (the Coder crew), or File issue
/// to save it on GitHub for later (prefilled, screenshot on the clipboard).
/// No type: pointing at something means "change it here".
struct BugCardView: View {
    let message: ChatMessage

    @Environment(BotBrain.self) private var brain
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(PreviewController.self) private var preview
    @Environment(FleetConnection.self) private var connection
    /// Fix it now's model: what the run would get, and what you picked here.
    @State private var choice: ModelChoice?
    @State private var picked: String?

    private var draft: BugDraft? {
        try? JSONDecoder().decode(BugDraft.self, from: Data(message.content.utf8))
    }

    var body: some View {
        if let draft {
            CardView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label(draft.title, systemImage: "exclamationmark.triangle").font(AppFont.headline())
                    Text("\(draft.page)\(draft.viewport.map { " · \($0)px wide" } ?? "")")
                        .font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                    Text(draft.headline).font(AppFont.body())
                    if !draft.facts.isEmpty { TechnicalDetails(text: draft.details) }
                    if store.sentRun(for: message) == nil { modelRow }
                    HStack {
                        Button("File issue", systemImage: "arrow.up.forward.square") { file(draft) }
                            .buttonStyle(.bordered)
                            .disabled(draft.issueURL == nil)
                        Spacer()
                        if let sent = store.sentRun(for: message)?.id {
                            // Already sent: go to its card instead of making another.
                            Button("Sent to Coder", systemImage: "checkmark") { router.focusRunId = sent }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Fix it now", systemImage: "hammer") { fix(draft) }
                                .buttonStyle(.borderedProminent).tint(Color.brandGreen)
                        }
                    }
                    Text(connection.isPaired ? "Fix it now changes it in this task. File issue saves it on GitHub for later and changes nothing."
                                             : "Pair with darkmux to run fixes. File issue saves it on GitHub for later.")
                        .font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .chatColumn(alignment: .leading)
            // The model, chosen like any dispatch's (mode, Auto order), so
            // Fix it now and the model are one step.
            .task(id: message.id) {
                guard connection.isPaired, store.sentRun(for: message) == nil, let bot else { return }
                choice = await brain.runs.modelChoice(crew: .coder, bot: bot)
            }
        }
    }

    /// The model Fix it now runs on, changeable for this fix: the dispatch
    /// card's own row (`ModelPickRow`).
    @ViewBuilder private var modelRow: some View {
        if let choice {
            ModelPickRow(choice: choice, current: picked ?? choice.profile, options: brain.runs.choices(crew: .coder),
                         line: { brain.runs.modelLine($0, crew: .coder) }, pick: { picked = $0 })
        }
    }

    private var store: BotStore { BotStore(context: context) }
    private var bot: Bot? { message.conversation?.roleId.flatMap(store.bot(id:)) }

    private func file(_ draft: BugDraft) {
        guard let url = draft.issueURL else { return }
        Task {
            let copied = await copySnapshot()
            openURL(url)
            if let conversation = message.conversation {
                store.append(.system, copied ? "Opened a prefilled issue on GitHub. The preview screenshot is on your clipboard: paste it into the issue."
                                             : "Opened a prefilled issue on GitHub.", to: conversation)
            }
        }
    }

    private func fix(_ draft: BugDraft) {
        guard let bot else { return }
        let (run, isNew) = store.fixBug(message, draft: draft, bot: bot)
        guard isNew else { router.focusRunId = run.id; return }
        // One tap: Fix it now is the approval, on the model shown above. Only
        // what needs deciding (a work copy, a model that isn't running) is
        // left on the dispatch card.
        if choice == nil {
            Task { await brain.runs.chooseProfile(for: run) }
        } else if !brain.runs.startNow(run, choice: choice, picked: picked, store: store) {
            router.focusRunId = run.id
        }
    }

    private func copySnapshot() async -> Bool {
        // This bug's own crop when it came from a pick; else this bot's
        // preview as it is now; never another bot's page or a stale crop.
        var png = draft?.selector != nil ? BugCrops.shared[message.id] : nil
        if png == nil { png = await preview.snapshotPNG(bot: bot?.id) }
        guard let png else { return false }
        return copy(png)
    }

    private func copy(_ png: Data) -> Bool { Clipboard.copyImage(png) }
}
