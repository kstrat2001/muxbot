import SwiftUI

/// Right-click (or long-press) actions on a bot: clear its conversation, or
/// delete it after confirming. Runs stay in Activity when a thread is cleared.
struct BotContextMenu: ViewModifier {
    let bot: Bot?

    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(BotBrain.self) private var brain
    @State private var confirmDelete = false
    @State private var confirmClear = false

    private var name: String { bot?.name ?? LeadBot.name }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                #if os(macOS)
                if let bot {
                    Button("Bot Info…", systemImage: "info.circle") { router.infoBotId = bot.id }
                    Divider()
                }
                #endif
                Button("Clear Conversation…", systemImage: "eraser") { confirmClear = true }
                if bot != nil {
                    Divider()
                    Button("Delete \(name)…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
            .confirmationDialog("Clear \(name)'s conversation?", isPresented: $confirmClear) {
                Button("Clear Conversation", role: .destructive) {
                    BotStore(context: context).clearConversation(bot.map { .bot($0.id) } ?? .lead)
                }
            } message: {
                Text("The messages go; runs stay in Activity.")
            }
            .confirmationDialog("Delete \(name)?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { delete() }
            } message: {
                Text("Its running work and preview stop, and its conversation, runs and links go too. darkmux's work copy and your project folder are left alone.")
            }
    }

    private func delete() {
        guard let bot else { return }
        Task {
            // Its runs are stopped on darkmux and its preview too, first; if
            // darkmux won't stop a run, the bot stays and its thread says why.
            let store = BotStore(context: context)
            if let problem = await brain.runs.prepareToDelete(bot, store: store) {
                store.append(.system, problem, to: store.conversation(for: .bot(bot.id)))
                return
            }
            if router.context.botId == bot.id {
                router.sidebar = .lead
                router.path = []
            }
            store.delete(bot)
        }
    }
}

extension View {
    func botContextMenu(_ bot: Bot?) -> some View { modifier(BotContextMenu(bot: bot)) }
}
