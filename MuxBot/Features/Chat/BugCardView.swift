import SwiftUI
import SwiftData

/// A drafted bug: what you described, measured page facts, and two ways
/// forward: file it on GitHub (prefilled, screenshot on the clipboard) or
/// send it straight to the Coder crew.
struct BugCardView: View {
    let message: ChatMessage

    @Environment(BotBrain.self) private var brain
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Environment(PreviewController.self) private var preview
    @Environment(FleetConnection.self) private var connection

    private var draft: BugDraft? {
        try? JSONDecoder().decode(BugDraft.self, from: Data(message.content.utf8))
    }

    var body: some View {
        if let draft {
            CardView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label("Bug: \(draft.title)", systemImage: "ladybug").font(AppFont.headline())
                    Text("\(draft.page)\(draft.viewport.map { " · \($0)px wide" } ?? "")")
                        .font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                    Text(draft.headline).font(AppFont.body())
                    if !draft.facts.isEmpty { TechnicalDetails(text: draft.details) }
                    HStack {
                        Button("File on GitHub", systemImage: "arrow.up.forward.square") { file(draft) }
                            .buttonStyle(.bordered)
                            .disabled(draft.issueURL == nil)
                        Spacer()
                        if let sent = store.sentRun(for: message)?.id {
                            // Already sent: go to its card instead of making another.
                            Button("Sent to Coder", systemImage: "checkmark") { router.focusRunId = sent }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Fix it now", systemImage: "hammer") { fix(draft) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    Text(connection.isPaired ? "Fixes run on darkmux after you approve." : "Pair with darkmux to run fixes.")
                        .font(AppFont.caption()).foregroundStyle(Color.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .chatColumn(alignment: .leading)
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
        // The model is chosen like any other dispatch (mode, Auto order).
        Task { await brain.runs.chooseProfile(for: run) }
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
