import SwiftUI
import SwiftData

/// The macOS / iPad sidebar (`SidebarLayout`): Mux Bot featured on top, then
/// each bot (character, name, unread dot, status), "New bot", then Activity.
struct BotSidebar: View {
    @Environment(AppRouter.self) private var router
    @Environment(FleetConnection.self) private var connection
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Bot.createdAt) private var bots: [Bot]
    @Query(sort: \ChatConversation.createdAt) private var threads: [ChatConversation]

    var body: some View {
        @Bindable var router = router
        list
        #if DEBUG && os(macOS)
            .task { if UserDefaults.standard.bool(forKey: "renderSidebarRows") { Self.renderRows(bots) } }
        #endif
    }

    private var list: some View {
        @Bindable var router = router
        return ScrollViewReader { proxy in List(selection: $router.sidebar) {
            Section {
                Button { router.sidebar = .lead } label: {
                    LeadBotTile(selected: router.sidebar == .lead, unread: unread(nil))
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .botContextMenu(nil)   // ⌘1 (Go menu) opens it from the keyboard
            }
            Section {
                ForEach(bots) { bot in
                    Self.row(name: bot.name, look: bot.look, id: bot.id, unread: unread(bot.id), state: NeedsYou.shownState(bot))
                        #if os(macOS)
                        .modifier(SidebarInfoButton(bot: bot))   // inside the row, so the tag stays outermost
                        #endif
                        .tag(SidebarItem.bot(bot.id))
                        .id(bot.id)
                        .help(Self.waitingText(bot) ?? bot.name)
                        .accessibilityValue(Self.waitingText(bot) ?? "")
                        .botContextMenu(bot)
                }
                // One way in: projects first, a bot with no project last.
                Button { router.showStartProject = true } label: {
                    plainRow(NewEntry.rowTitle, systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.secondaryText)
                if bots.isEmpty {
                    Button { BotStore(context: modelContext).addExample() } label: {
                        plainRow("Add an example bot", systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondaryText)
                }
            } header: {
                Text("Bots")
            }
            Section {
                plainRow("Activity", systemImage: "waveform.path.ecg").tag(SidebarItem.activity)
            }
        }
        .toolbar {
            // New is always one tap away (also File › New… ⌘N).
            ToolbarItem {
                Button(NewEntry.rowTitle, systemImage: "plus") { router.showStartProject = true }
                    .help("New (⌘N)")
            }
            ToolbarItem {
                #if os(iOS)
                Button("Settings", systemImage: "gearshape") { router.showSettings = true }
                #else
                Button("darkmux", systemImage: connection.isPaired ? "link.circle.fill" : "link.circle") { router.showPairing = true }
                    .help(connection.isPaired ? "Paired with darkmux" : "Pair with darkmux")
                #endif
            }
        }
        .onChange(of: router.sidebar) { router.path = [] }
        // ⌘I: Bot info is a popover on the bot's row, so the row is
        // scrolled into view (and built) first, never shown later.
        .onChange(of: router.infoBotId) { if let id = router.infoBotId { proxy.scrollTo(id) } }
        }
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

    static func row(name: String, look: BotLook, id: UUID?, unread: Bool, state: BotState?) -> some View {
        HStack(spacing: Spacing.sm) {
            BotAvatarView(look: look, mood: state.map(AvatarMood.init) ?? .idle, size: Self.avatarSize, blinkId: id)
            Text(name).lineLimit(1)
            Spacer(minLength: 0)
            // macOS: the (i) sits before the badges, side by side, never on top.
            if let id { SidebarInfoGlyph(botId: id, name: name) }
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
        let waiting = NeedsYou.waiting(runs)
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

/// The (i) on a bot's sidebar row (macOS): the row reports hover here and
/// anchors Bot info's popover; `SidebarInfoGlyph` draws the button inside
/// the row, before its badges.
struct SidebarInfoButton: ViewModifier {
    let bot: Bot
    @Environment(AppRouter.self) private var router
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .environment(\.sidebarInfo, SidebarInfoContext(enabled: true, hovering: hovering))
            .onHover { hovering = $0 }
            .popover(isPresented: Binding(get: { router.infoBotId == bot.id },
                                          set: { if !$0, router.infoBotId == bot.id { router.infoBotId = nil } }),
                     arrowEdge: .trailing) {
                NavigationStack { BotInfoView(bot: bot) }
                    .frame(width: 440, height: 580)
            }
    }
}

struct SidebarInfoContext: Equatable {
    var enabled = false
    var hovering = false
}

extension EnvironmentValues {
    /// Whether this row shows an (i), and whether it's hovered.
    @Entry var sidebarInfo = SidebarInfoContext()
}

/// The (i) itself, shown while its row is hovered, selected or open.
struct SidebarInfoGlyph: View {
    let botId: UUID
    let name: String
    @Environment(\.sidebarInfo) private var info
    @Environment(AppRouter.self) private var router

    var body: some View {
        let open = router.infoBotId == botId
        if info.enabled, info.hovering || open || router.sidebar == .bot(botId) {
            Button { router.infoBotId = botId } label: {
                Image(systemName: open ? "info.circle.fill" : "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Bot info (⌘I)")
            .accessibilityLabel("\(name) info")
        }
    }
}
