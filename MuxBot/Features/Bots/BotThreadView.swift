import SwiftUI
import SwiftData

/// One bot's thread (or the lead bot's). You type in the shared `BotBar`,
/// which follows navigation here; this view shows the conversation.
struct BotThreadView: View {
    let context: ChatContext

    @Environment(\.modelContext) private var modelContext
    @Environment(BotBrain.self) private var brain
    @Query private var conversations: [ChatConversation]
    @Query private var matches: [MuxRole]

    init(context: ChatContext) {
        self.context = context
        let roleId = context.botId
        _conversations = Query(filter: #Predicate<ChatConversation> { $0.roleId == roleId })
        // The lead bot is not stored, so its lookup matches nothing.
        let botId = roleId ?? UUID()
        _matches = Query(filter: #Predicate<MuxRole> { $0.id == botId })
    }

    private var bot: MuxRole? { matches.first }
    private var title: String { context.botId == nil ? LeadBot.name : (bot?.name ?? "Bot") }

    var body: some View {
        Group {
            if context.botId != nil && bot == nil {
                EmptyStateView(systemImage: "questionmark.circle", title: "Bot not found", message: "It may have been removed.")
            } else if let conversation = conversations.first {
                ChatView(conversation: conversation, isThinking: brain.isThinking)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .toolbar {
            if let bot {
                ToolbarItem(placement: .primaryAction) {
                    Label(bot.state.label, systemImage: bot.systemImage)
                        .font(AppFont.footnote(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { greetIfNew() }
    }

    private func greetIfNew() {
        let store = RoleStore(context: modelContext)
        if context.botId != nil && bot == nil { return }
        let conversation = store.conversation(for: context)
        guard (conversation.messages ?? []).isEmpty else { return }
        let hello = bot.map { "Hi, I'm \($0.name). \($0.instructions)" }
            ?? "Hi, I'm \(LeadBot.name). Tell me what needs doing and I'll get the right bot on it."
        store.append(.assistant, hello, to: conversation)
    }
}
