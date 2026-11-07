import SwiftUI
import SwiftData

/// The macOS / iPad sidebar: Mux Bot, each bot (symbol, name, unread dot,
/// status), "New bot", then Activity.
struct BotSidebar: View {
    @Environment(AppRouter.self) private var router
    @Environment(FleetConnection.self) private var connection
    @Query(sort: \Bot.createdAt) private var bots: [Bot]
    @Query private var threads: [ChatConversation]

    var body: some View {
        @Bindable var router = router
        List(selection: $router.sidebar) {
            Section {
                row(name: LeadBot.name, systemImage: LeadBot.systemImage, unread: unread(nil), state: nil)
                    .tag(SidebarItem.lead)
                ForEach(bots) { bot in
                    row(name: bot.name, systemImage: bot.systemImage, unread: unread(bot.id), state: bot.state)
                        .tag(SidebarItem.bot(bot.id))
                        .help(Self.waitingText(bot) ?? bot.name)
                        .accessibilityValue(Self.waitingText(bot) ?? "")
                }
                Button { router.showNewBot = true } label: {
                    Label("New bot", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } header: {
                Text("Bots")
            }
            Section {
                Label("Activity", systemImage: "waveform.path.ecg").tag(SidebarItem.activity)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("darkmux", systemImage: connection.isPaired ? "link.circle.fill" : "link.circle") { router.showPairing = true }
                    .help(connection.isPaired ? "Paired with darkmux" : "Pair with darkmux")
            }
        }
        .onChange(of: router.sidebar) { router.path = [] }
    }

    private func unread(_ botId: UUID?) -> Bool {
        let selected: Bool = switch router.sidebar {
        case .lead?: botId == nil
        case let .bot(id)?: botId == id
        default: false
        }
        return !selected && (threads.first { $0.roleId == botId }?.hasUnread ?? false)
    }

    private func row(name: String, systemImage: String, unread: Bool, state: BotState?) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.brandGreen)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(name).lineLimit(1)
            Spacer(minLength: 0)
            if unread {
                Circle().fill(Color.brandBlue).frame(width: 8, height: 8).accessibilityLabel("Unread")
            }
            if let state, state != .ready {
                StatusBadge(kind: state.kind)
            }
        }
    }

    /// "1 result waiting for you", "2 things waiting for you", "Working".
    static func waitingText(_ bot: Bot) -> String? {
        let runs = bot.runs ?? []
        let waiting = runs.filter { $0.phase.awaitsYou }
        if waiting.count == 1 {
            switch waiting[0].phase {
            case .result: return "1 result waiting for you"
            case .proposed: return "1 dispatch waiting for your approval"
            default: return "1 thing waiting for you"
            }
        }
        if waiting.count > 1 { return "\(waiting.count) things waiting for you" }
        if runs.contains(where: { $0.phase == .running }) { return "Working" }
        return nil
    }
}
