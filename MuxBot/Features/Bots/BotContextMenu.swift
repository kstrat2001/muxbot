import SwiftUI

/// Right-click (or long-press) actions on a bot: clear its conversation, or
/// delete it after confirming. Runs stay in Activity when a thread is cleared.
struct BotContextMenu: ViewModifier {
    let bot: Bot?

    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @State private var confirmDelete = false
    @State private var confirmClear = false

    private var name: String { bot?.name ?? LeadBot.name }

    func body(content: Content) -> some View {
        content
            .contextMenu {
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
                Text("Its conversation, runs and links go too. darkmux's work copy and your project folder are left alone.")
            }
    }

    private func delete() {
        guard let bot else { return }
        if router.context.botId == bot.id {
            router.sidebar = .lead
            router.path = []
        }
        BotStore(context: context).delete(bot)
    }
}

extension View {
    func botContextMenu(_ bot: Bot?) -> some View { modifier(BotContextMenu(bot: bot)) }
}
