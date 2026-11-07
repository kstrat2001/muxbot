import SwiftUI

/// How the bot read your message ("Bug report", "Question", ...). Tap to
/// switch, and the bot answers again under the intent you picked.
struct IntentChip: View {
    let message: ChatMessage

    @Environment(\.modelContext) private var context
    @Environment(BotBrain.self) private var brain

    private var intent: Intent? { message.intentRaw.flatMap(Intent.init(rawValue:)) }

    var body: some View {
        Menu {
            ForEach(Intent.allCases, id: \.self) { choice in
                Button(choice.label, systemImage: choice.systemImage) {
                    let store = BotStore(context: context)
                    Task { await brain.reinterpret(message, as: choice, store: store) }
                }
                .disabled(choice == intent)
            }
        } label: {
            Label(intent?.label ?? "Chat", systemImage: intent?.systemImage ?? "bubble.left")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(brain.isThinking)
        .accessibilityHint("Change how the bot reads this message")
    }
}
