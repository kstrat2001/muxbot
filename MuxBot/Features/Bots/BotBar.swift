import SwiftUI
import SwiftData

/// The one chat bar, owned by the Bots tab so it stays on screen across
/// navigation. It talks to whichever bot you are looking at (the lead bot
/// on Home). Proposed actions are cards in the thread, not here.
struct BotBar: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(BotBrain.self) private var brain
    @Environment(PreviewController.self) private var preview
    @Query(sort: \Bot.createdAt) private var bots: [Bot]

    @Query private var runs: [BotRun]

    /// The run a Tweak is aimed at, if it belongs to the thread on screen.
    private var tweakRun: BotRun? {
        guard let id = brain.tweakRunId, let run = runs.first(where: { $0.id == id }),
              run.bot?.id == router.context.botId else { return nil }
        return run
    }

    private var listenerName: String {
        router.context.botId.flatMap { id in bots.first { $0.id == id }?.name } ?? LeadBot.name
    }

    var body: some View {
        @Bindable var router = router
        VStack(spacing: Spacing.md) {
            if let note = brain.fallbackNote {
                Label(note, systemImage: "info.circle")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let run = tweakRun {
                HStack {
                    Label("Tweak: \(run.task)", systemImage: "pencil")
                        .font(AppFont.caption())
                        .lineLimit(1)
                    Spacer()
                    Button("Stop tweaking", systemImage: "xmark.circle.fill") { brain.tweakRunId = nil }
                        .labelStyle(.iconOnly)
                }
                .foregroundStyle(.secondary)
            }
            if let element = preview.picked, router.context.botId != nil {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: element.intent == "bug" ? "ladybug" : "scope").accessibilityHidden(true)
                    Text(element.chip).lineLimit(1)
                    Button("Remove", systemImage: "xmark.circle.fill") { preview.clearPick() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .font(AppFont.caption(.semibold))
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Capsule().fill(Color.brandGreen.opacity(0.18)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("About \(element.chip)")
            }
            HStack(spacing: Spacing.sm) {
                TextField(tweakRun != nil ? "What should change?" : preview.picked != nil ? "What about it?" : "Message \(listenerName)…", text: $router.barDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled((router.barDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && preview.picked == nil) || brain.isThinking)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(.bar)
        .onChange(of: preview.picked) {
            // "Report a bug here" from the preview starts a bug report.
            if preview.picked?.intent == "bug", router.barDraft.isEmpty { router.barDraft = "bug: " }
        }
    }

    private func send() {
        let text = router.barDraft
        let element = router.context.botId == nil ? nil : preview.picked
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || element != nil, !brain.isThinking else { return }
        router.barDraft = ""
        preview.clearPick()   // a pick is about one message
        let chat = router.context
        let store = BotStore(context: context)
        if let run = tweakRun {
            brain.tweak(text, run: run, store: store)
            return
        }
        Task { await brain.send(text, in: chat, store: store, element: element) }
    }
}
