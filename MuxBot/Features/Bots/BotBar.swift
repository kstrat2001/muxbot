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
    @FocusState private var barFocused: Bool

    /// The run a Tweak is aimed at, if it belongs to the thread on screen.
    private var tweakRun: BotRun? {
        guard let id = brain.runs.tweakRunId, let run = runs.first(where: { $0.id == id }),
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
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let run = tweakRun {
                HStack {
                    Label("Tweak: \(run.task)", systemImage: "pencil")
                        .font(AppFont.caption())
                        .lineLimit(1)
                    Spacer()
                    Button("Stop tweaking", systemImage: "xmark.circle.fill") { brain.runs.tweakRunId = nil }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut(.cancelAction)
                        .help("Stop tweaking (Esc)")
                }
                .foregroundStyle(Color.secondaryText)
            }
            if let element = preview.picked, router.context.botId != nil {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "scope").accessibilityHidden(true)
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
            if !chips.isEmpty, ChatShortcuts.showsRow(draft: router.barDraft, tweaking: tweakRun != nil,
                                                      picked: preview.picked != nil, waitingCard: hasWaitingCard) {
                ChatShortcutRow(chips: chips, run: run)
            }
            #if os(macOS)
            HStack(spacing: Spacing.sm) {
                field.textFieldStyle(.roundedBorder)
                sendButton.font(.title2)
            }
            #else
            // Messages-style: a capsule with the send button inside.
            HStack(alignment: .bottom, spacing: Spacing.xs) {
                field.textFieldStyle(.plain)
                    .padding(.vertical, Spacing.sm)
                    .padding(.leading, Spacing.md)
                sendButton.font(.title)
                    .padding(.trailing, 2)
                    .padding(.bottom, 2)
            }
            .background(Capsule().strokeBorder(Color.fieldBorder))
            #endif
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(.bar)
    }

    /// The shortcuts for the thread on screen.
    private var chips: [ChatShortcut] {
        guard let id = router.context.botId else { return ChatShortcuts.lead() }
        guard let bot = bots.first(where: { $0.id == id }) else { return [] }
        return ChatShortcuts.bot(.init(hasRepo: !bot.repoSlugs.isEmpty, canPreview: brain.runs.canPreview(bot),
                                       skills: bot.skills.map(\.name)))
    }

    /// A dispatch or action card in this thread is waiting for Approve.
    private var hasWaitingCard: Bool {
        let botId = router.context.botId
        if runs.contains(where: { $0.phase == .proposed && $0.bot?.id == botId && botId != nil }) { return true }
        let thread = BotStore(context: context).existingConversation(for: router.context)
        return (thread?.messages ?? []).contains { $0.kind == .actionCard && $0.actionState == .waiting }
    }

    private func run(_ chip: ChatShortcut) {
        let chat = router.context
        let store = BotStore(context: context)
        Task { await ChatShortcuts.run(chip, in: chat, brain: brain, store: store, router: router, preview: preview) }
    }

    private var field: some View {
        let placeholder = tweakRun != nil ? String(localized: "What should change?") : preview.picked != nil ? String(localized: "What about it?") : String(localized: "Message \(listenerName)…")
        return TextField(placeholder, text: Bindable(router).barDraft, prompt: Text(placeholder).foregroundStyle(Color.secondaryText), axis: .vertical)
            .lineLimit(1...4)
            .focused($barFocused)
            .onSubmit(send)
            .onChange(of: router.focusBarRequest) { barFocused = true }
    }

    private var sendButton: some View {
        Button("Send", systemImage: "arrow.up.circle.fill", action: send)
            .labelStyle(.iconOnly)
            .disabled((router.barDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && preview.picked == nil) || brain.isThinking)
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
            brain.runs.tweak(text, run: run, store: store)
            return
        }
        Task { await brain.send(text, in: chat, store: store, element: element) }
    }
}
