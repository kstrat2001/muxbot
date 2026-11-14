import SwiftUI

/// A bot's proposed hand-off, new bot or new resource, saved in the thread.
/// Approve / Cancel while it waits; afterwards it shows what you decided.
struct ActionCardView: View {
    let message: ChatMessage

    @Environment(\.modelContext) private var context
    @Environment(BotBrain.self) private var brain

    /// The bot whose thread the card is in.
    private var botName: String {
        message.conversation?.roleId.flatMap { BotStore(context: context).bot(id: $0)?.name } ?? ""
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                switch message.action {
                case let .handOff(_, toName, task)?:
                    Label("Hand to \(toName)", systemImage: "arrowshape.turn.up.right").font(AppFont.headline())
                    Text(task).font(AppFont.body())
                case let .createBot(draft)?:
                    Label("New bot: \(draft.name)", systemImage: "plus.bubble").font(AppFont.headline())
                    Text(draft.instructions).font(AppFont.body())
                case let .dispatch(crew, task)?:
                    Label("Dispatch to \(crew.name)", systemImage: crew.systemImage).font(AppFont.headline())
                    Text(task).font(AppFont.body())
                case let .addResource(kind, value)?:
                    Label("Add \(kind.label.lowercased())", systemImage: kind.systemImage).font(AppFont.headline())
                    Text(value).font(AppFont.body()).textSelection(.enabled)
                case let .tweak(_, change)?:
                    Label("Tweak the last run", systemImage: "pencil").font(AppFont.headline())
                    Text(change).font(AppFont.body())
                case let .setUpPreview(setup)?:
                    PreviewSetupCardView(message: message, setup: setup)
                case let .setUpPlaybook(setup)?:
                    PlaybookSetupCardView(message: message, setup: setup)
                case let .app(action, _, detail)?:
                    Label(action.cardTitle(bot: botName), systemImage: action.systemImage).font(AppFont.headline())
                    if !detail.isEmpty { Text(detail).font(AppFont.body()) }
                case nil:
                    Text(message.content).font(AppFont.body())
                }
                if message.action?.hasOwnButtons == true {
                    // Its own buttons: Approve needs your folder first.
                } else {
                switch message.actionState {
                case .waiting:
                    HStack {
                        Button("Cancel", role: .cancel) { decide(false) }.buttonStyle(.bordered)
                        Spacer()
                        Button("Approve") { decide(true) }.buttonStyle(.borderedProminent).tint(Color.brandGreen)
                    }
                case .approved:
                    Label("Approved", systemImage: "checkmark.circle").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                case .canceled:
                    Label("Canceled", systemImage: "xmark.circle").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .chatColumn(alignment: .leading)
    }

    private func decide(_ approve: Bool) {
        brain.resolve(message, approve: approve, store: BotStore(context: context))
    }
}
