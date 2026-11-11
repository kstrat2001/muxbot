import SwiftUI

/// Right-click (or long-press) actions on a bot: clear its conversation
/// (Undo in the thread), or archive it (Restore from Archived bots, where
/// Delete lives). Runs stay in Activity when a thread is cleared.
struct BotContextMenu: ViewModifier {
    let bot: Bot?

    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(BotBrain.self) private var brain
    @State private var confirmClear = false
    @State private var archiveProblem: String?

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
                    Button("Archive \(name)", systemImage: "archivebox") { archive() }
                }
            }
            .confirmationDialog("Clear \(name)'s conversation?", isPresented: $confirmClear) {
                Button("Clear Conversation", role: .destructive) {
                    router.cleared = BotStore(context: context).clearConversation(bot.map { .bot($0.id) } ?? .lead)
                }
            } message: {
                Text("The messages go; runs stay in Activity. You can undo it until Mux Bot quits.")
            }
            .alert("Can't archive \(name) yet", isPresented: Binding(get: { archiveProblem != nil }, set: { if !$0 { archiveProblem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(archiveProblem ?? "")
            }
    }

    /// Out of the lists, everything kept; its preview stops. Refused while
    /// work runs or waits on you, so nothing hides in the archive.
    private func archive() {
        guard let bot else { return }
        if let problem = BotStore.archiveBlocker(bot) { archiveProblem = problem; return }
        if router.context.botId == bot.id {
            router.sidebar = .lead
            router.path = []
        }
        BotStore(context: context).archive(bot)
        Task { await brain.runs.stopPreview(for: bot) }
    }
}

extension View {
    func botContextMenu(_ bot: Bot?) -> some View { modifier(BotContextMenu(bot: bot)) }
}
