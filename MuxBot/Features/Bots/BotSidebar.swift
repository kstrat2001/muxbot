import SwiftUI
import SwiftData

/// The macOS / iPad sidebar: Mux Bot, each bot (character, name, unread dot,
/// status), "New bot", then Activity.
struct BotSidebar: View {
    @Environment(AppRouter.self) private var router
    @Environment(FleetConnection.self) private var connection
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Bot.createdAt) private var bots: [Bot]
    @Query private var threads: [ChatConversation]

    var body: some View {
        @Bindable var router = router
        list
        #if DEBUG && os(macOS)
            .task { if UserDefaults.standard.bool(forKey: "renderSidebarRows") { Self.renderRows(bots) } }
        #endif
    }

    private var list: some View {
        @Bindable var router = router
        return List(selection: $router.sidebar) {
            Section {
                row(name: LeadBot.name, look: .lead, id: nil, unread: unread(nil), state: nil)
                    .tag(SidebarItem.lead)
                    .botContextMenu(nil)
                ForEach(bots) { bot in
                    row(name: bot.name, look: bot.look, id: bot.id, unread: unread(bot.id), state: bot.state)
                        .tag(SidebarItem.bot(bot.id))
                        .help(Self.waitingText(bot) ?? bot.name)
                        .accessibilityValue(Self.waitingText(bot) ?? "")
                        .botContextMenu(bot)
                }
                Button { router.showNewBot = true } label: {
                    plainRow("New bot", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                if bots.isEmpty {
                    Button { BotStore(context: modelContext).addExample() } label: {
                        plainRow("Add an example bot", systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Bots")
            }
            Section {
                plainRow("Activity", systemImage: "waveform.path.ecg").tag(SidebarItem.activity)
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

    /// Avatar size in the sidebar: big enough on the Mac for the face to
    /// read next to the name; iPad lists keep their compact size.
    #if os(macOS)
    static let avatarSize: CGFloat = 38
    static let rowPadding: CGFloat = 4
    #else
    static let avatarSize: CGFloat = 26
    static let rowPadding: CGFloat = 0
    #endif

    private func row(name: String, look: BotLook, id: UUID?, unread: Bool, state: BotState?) -> some View {
        HStack(spacing: Spacing.sm) {
            BotAvatarView(look: look, mood: state.map(AvatarMood.init) ?? .idle, size: Self.avatarSize, blinkId: id)
            Text(name).lineLimit(1)
            Spacer(minLength: 0)
            if unread {
                Circle().fill(Color.brandBlue).frame(width: 8, height: 8).accessibilityLabel("Unread")
            }
            if let state, state != .ready {
                StatusBadge(kind: state.kind)
            }
        }
        .padding(.vertical, Self.rowPadding)
    }

    /// A non-bot row (New bot, Activity) with its symbol in an avatar-wide
    /// slot, so its text lines up with the bot names.
    private func plainRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .frame(width: Self.avatarSize)
            Text(title)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Self.rowPadding)
    }

    #if DEBUG && os(macOS)
    /// `-renderSidebarRows YES`: draws the sidebar's rows (at 2x) to
    /// muxbot-sidebar-rows.png in the app's temp folder, for checking sizes
    /// without a screen capture.
    @MainActor
    static func renderRows(_ bots: [Bot]) {
        let rows = VStack(alignment: .leading, spacing: 2) {
            ForEach([(LeadBot.name, BotLook.lead, BotState?.none)] + bots.map { ($0.name, $0.look, Optional($0.state)) }, id: \.0) { item in
                HStack(spacing: Spacing.sm) {
                    BotAvatarView(look: item.1, mood: item.2.map(AvatarMood.init) ?? .idle, size: avatarSize)
                    Text(item.0)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, rowPadding)
            }
            HStack(spacing: Spacing.sm) {
                Image(systemName: "waveform.path.ecg").frame(width: avatarSize)
                Text("Activity")
                Spacer(minLength: 0)
            }
            .padding(.vertical, rowPadding)
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: rows)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muxbot-sidebar-rows.png"))
    }
    #endif

    /// "1 result waiting for you", "2 things waiting for you", "Running".
    static func waitingText(_ bot: Bot) -> String? {
        let runs = bot.runs ?? []
        let waiting = runs.filter(\.needsYou)
        if waiting.count == 1 {
            switch waiting[0].phase {
            case .result: return "1 result waiting for you"
            case .proposed: return "1 dispatch waiting for your approval"
            default: return "1 thing waiting for you"
            }
        }
        if waiting.count > 1 { return "\(waiting.count) things waiting for you" }
        if runs.contains(where: { $0.phase == .running }) { return "Running" }
        return nil
    }
}
