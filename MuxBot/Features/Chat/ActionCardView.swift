import SwiftUI

/// A bot's proposed hand-off, new bot or new resource, saved in the thread.
/// Approve / Cancel while it waits; afterwards it shows what you decided.
struct ActionCardView: View {
    let message: ChatMessage

    @Environment(\.modelContext) private var context
    @Environment(BotBrain.self) private var brain

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
                case nil:
                    Text(message.content).font(AppFont.body())
                }
                switch message.actionState {
                case .waiting:
                    HStack {
                        Button("Cancel", role: .cancel) { decide(false) }.buttonStyle(.bordered)
                        Spacer()
                        Button("Approve") { decide(true) }.buttonStyle(.borderedProminent)
                    }
                case .approved:
                    Label("Approved", systemImage: "checkmark.circle").font(AppFont.footnote()).foregroundStyle(.secondary)
                case .canceled:
                    Label("Canceled", systemImage: "xmark.circle").font(AppFont.footnote()).foregroundStyle(.secondary)
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
