import SwiftUI
import SwiftData

/// The one chat bar, owned by the Bots tab so it stays on screen across
/// navigation. It talks to whichever bot you are looking at (the lead bot
/// on Home). A proposed action shows here with Approve / Cancel. The mic is
/// a placeholder until speech input lands.
struct BotBar: View {
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(BotBrain.self) private var brain
    @Query(sort: \MuxRole.createdAt) private var bots: [MuxRole]

    private var listenerName: String {
        router.context.botId.flatMap { id in bots.first { $0.id == id }?.name } ?? LeadBot.name
    }

    var body: some View {
        @Bindable var router = router
        VStack(spacing: Spacing.md) {
            if let pending = brain.pending, pending.context == router.context {
                ActionCard(action: pending.action,
                           approve: { brain.approve(in: RoleStore(context: context)) },
                           cancel: { brain.cancel() })
            }
            if let note = brain.fallbackNote {
                Label(note, systemImage: "info.circle")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Spacing.sm) {
                TextField("Message \(listenerName)…", text: $router.barDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(router.barDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || brain.isThinking)
                Button("Talk (coming soon)", systemImage: "mic.fill") {}
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .disabled(true)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(.bar)
    }

    private func send() {
        let text = router.barDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !brain.isThinking else { return }
        router.barDraft = ""
        let chat = router.context
        let store = RoleStore(context: context)
        Task { await brain.send(text, in: chat, store: store) }
    }
}

private struct ActionCard: View {
    let action: BotAction
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                switch action {
                case let .handOff(_, toName, task):
                    Text("Hand to \(toName)").font(AppFont.headline())
                    Text(task).font(AppFont.body())
                case let .createBot(draft):
                    Text("New bot: \(draft.name)").font(AppFont.headline())
                    Text(draft.instructions).font(AppFont.body())
                }
                HStack {
                    Button("Cancel", role: .cancel, action: cancel).buttonStyle(.bordered)
                    Spacer()
                    Button("Approve", action: approve).buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
