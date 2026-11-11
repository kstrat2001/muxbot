import SwiftUI
import SwiftData

/// Archived bots: out of the lists with everything kept. Restore brings one
/// back as it was; Delete (here only, after confirming) removes it for good.
struct ArchivedBotsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Environment(BotBrain.self) private var brain
    @Query(filter: #Predicate<Bot> { $0.archivedAt != nil }, sort: [SortDescriptor(\Bot.archivedAt, order: .reverse)]) private var bots: [Bot]
    @State private var confirmDelete: Bot?
    @State private var problem: String?

    var body: some View {
        Group {
            if bots.isEmpty {
                EmptyStateView(systemImage: "archivebox", title: "No archived bots",
                               message: "Archive a bot from its menu to put it away. Its conversation and runs are kept.")
            } else {
                List {
                    Section {
                        ForEach(bots) { bot in row(bot) }
                    } footer: {
                        Text("Archived bots keep their conversation, runs and links, on every device.")
                    }
                }
            }
        }
        .navigationTitle("Archived Bots")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(get: { confirmDelete != nil },
                                                                                          set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let bot = confirmDelete { delete(bot) } }
        } message: {
            Text("This can't be undone. Its conversation, runs and links go for good, on every device. darkmux's work copy and your project folder are left alone.")
        }
        .alert("Not deleted", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func row(_ bot: Bot) -> some View {
        HStack(spacing: Spacing.sm) {
            BotAvatarView(look: bot.look, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name).lineLimit(1)
                if let at = bot.archivedAt {
                    Text("Archived \(at, format: .relative(presentation: .named))")
                        .font(AppFont.caption())
                        .foregroundStyle(Color.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Button("Restore") { restore(bot) }
                .buttonStyle(.bordered)
            Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = bot }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Delete \(bot.name)")
        }
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") { restore(bot) }
            Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = bot }
        }
    }

    /// Back in the lists, and open.
    private func restore(_ bot: Bot) {
        BotStore(context: context).restore(bot)
        router.navigate(to: .bot(bot.id))
        if bots.count <= 1 { dismiss() }
    }

    private func delete(_ bot: Bot) {
        Task {
            // Anything still running for it stops on darkmux first; if
            // darkmux won't stop a run, the bot stays and this says why.
            let store = BotStore(context: context)
            if let refusal = await brain.runs.prepareToDelete(bot, store: store) {
                problem = refusal
                return
            }
            store.delete(bot)
        }
    }
}
