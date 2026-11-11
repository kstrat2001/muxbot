import SwiftUI
import SwiftData

/// Which list of put-away bots: hidden (still working, just out of the
/// sidebar and Home) or archived (put away, everything kept).
enum PutAway: String, Identifiable {
    case hidden, archived
    var id: String { rawValue }
}

/// Hidden or archived bots. Hidden: Show puts one back in the sidebar, or
/// Archive. Archived: Restore brings one back as it was; Delete (here
/// only, after confirming) removes it for good.
struct ArchivedBotsView: View {
    let kind: PutAway

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Environment(BotBrain.self) private var brain
    @Query(sort: \Bot.createdAt) private var allBots: [Bot]
    @State private var confirmDelete: Bot?
    @State private var problem: String?

    private var bots: [Bot] {
        switch kind {
        case .hidden: allBots.filter(\.isHidden).sorted { ($0.hiddenAt ?? .distantPast) > ($1.hiddenAt ?? .distantPast) }
        case .archived: allBots.filter(\.isArchived).sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        }
    }

    var body: some View {
        Group {
            if bots.isEmpty {
                switch kind {
                case .hidden:
                    EmptyStateView(systemImage: "eye.slash", title: "No hidden bots",
                                   message: "Hide a bot from its menu to take it out of the sidebar. It keeps working as usual.")
                case .archived:
                    EmptyStateView(systemImage: "archivebox", title: "No archived bots",
                                   message: "Archive a bot from its menu to put it away. Its conversation and runs are kept.")
                }
            } else {
                List {
                    Section {
                        ForEach(bots) { bot in row(bot) }
                    } footer: {
                        switch kind {
                        case .hidden: Text("Hidden bots keep working and come back to the sidebar while something waits for you.")
                        case .archived: Text("Archived bots keep their conversation, runs and links, on every device.")
                        }
                    }
                }
            }
        }
        .navigationTitle(kind == .hidden ? "Hidden Bots" : "Archived Bots")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(get: { confirmDelete != nil },
                                                                                          set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let bot = confirmDelete { delete(bot) } }
        } message: {
            Text("This can't be undone. Its conversation, runs and links go for good, on every device. darkmux's work copy and your project folder are left alone.")
        }
        .alert(kind == .hidden ? "Not archived" : "Not deleted", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
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
                if let at = kind == .hidden ? bot.hiddenAt : bot.archivedAt {
                    Text(kind == .hidden ? "Hidden \(at, format: .relative(presentation: .named))"
                                         : "Archived \(at, format: .relative(presentation: .named))")
                        .font(AppFont.caption())
                        .foregroundStyle(Color.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Button(kind == .hidden ? "Show" : "Restore") { restore(bot) }
                .buttonStyle(.bordered)
            switch kind {
            case .hidden:
                Button("Archive", systemImage: "archivebox") { archive(bot) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Archive \(bot.name)")
            case .archived:
                Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = bot }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete \(bot.name)")
            }
        }
        .contextMenu {
            Button(kind == .hidden ? "Show in Sidebar" : "Restore", systemImage: "arrow.uturn.backward") { restore(bot) }
            switch kind {
            case .hidden: Button("Archive", systemImage: "archivebox") { archive(bot) }
            case .archived: Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = bot }
            }
        }
    }

    /// Back in the lists, and open.
    private func restore(_ bot: Bot) {
        BotStore(context: context).restore(bot)
        router.navigate(to: .bot(bot.id))
        if bots.isEmpty { dismiss() }
    }

    private func archive(_ bot: Bot) {
        if let blocker = BotStore.archiveBlocker(bot) { problem = blocker; return }
        BotStore(context: context).archive(bot)
        Task { await brain.runs.stopPreview(for: bot) }
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
