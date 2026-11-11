import SwiftUI
import SwiftData

/// "Your bots": Mux Bot featured on top (LeadBotTile), then bot tiles grouped Needs you /
/// Working / Ready from stored state. The bar at the bottom talks to the lead bot.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(FleetConnection.self) private var connection
    @Environment(\.modelContext) private var modelContext
    /// Archived bots are out of the grid (More › Archived Bots).
    @Query(filter: #Predicate<Bot> { $0.archivedAt == nil }, sort: \Bot.createdAt) private var roles: [Bot]
    @Query(filter: #Predicate<Bot> { $0.archivedAt != nil }) private var archived: [Bot]
    @Query(filter: #Predicate<ChatConversation> { $0.roleId == nil }, sort: \ChatConversation.createdAt) private var leadThreads: [ChatConversation]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)]

    var body: some View {
        Group {
            // No bots yet: start with what you want to get done.
            if roles.isEmpty { StartProjectView(inline: true) } else { grid }
        }
        .safeAreaInset(edge: .bottom) { BotBar() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                #if os(iOS)
                // Runs start from the Mac app for now; this says where.
                Button("darkmux", systemImage: "laptopcomputer") { router.showPairing = true }
                    .labelStyle(.titleAndIcon)
                    .accessibilityHint("How this app reaches darkmux")
                #else
                Button(connection.isPaired ? "darkmux: paired" : "Pair with darkmux",
                       systemImage: connection.isPaired ? "link.circle.fill" : "link.circle") { router.showPairing = true }
                    .labelStyle(.titleAndIcon)
                    .help(connection.isPaired ? "Paired with darkmux on this Mac" : "Pair with darkmux")
                #endif
                if !roles.isEmpty {
                    Button("Start a project", systemImage: "plus") { router.showStartProject = true }
                }
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("New bot", systemImage: "plus") { router.showNewBot = true }
                    if !archived.isEmpty {
                        Button("Archived Bots", systemImage: "archivebox") { router.showArchived = true }
                    }
                    if roles.isEmpty {
                        Button("Add an example bot", systemImage: "wand.and.stars") { BotStore(context: modelContext).addExample() }
                    }
                }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Button { router.navigate(to: .lead) } label: { LeadBotTile(unread: leadThreads.first?.hasUnread ?? false) }
                    .buttonStyle(.plain)
                ForEach(BotState.allCases, id: \.self) { state in
                    let group = roles.filter { NeedsYou.shownState($0) == state }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            if state != .ready { HStack(spacing: Spacing.sm) {
                                StatusBadge(kind: state.kind)
                                Text("\(group.count)")
                                    .font(AppFont.caption(.semibold))
                                    .foregroundStyle(Color.secondaryText)
                                    .accessibilityLabel("\(group.count) bots")
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                            }
                            LazyVGrid(columns: columns, spacing: Spacing.md) {
                                ForEach(group) { role in
                                    Button { router.navigate(to: .bot(role.id)) } label: {
                                        RoleTile(role: role)
                                    }
                                    .buttonStyle(.plain)
                                    .botContextMenu(role)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Spacing.lg)
        }
        .navigationTitle("Your bots")
    }
}

struct RoleTile: View {
    let role: Bot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .top) {
                    RoleAvatar(role: role, tint: tint)
                    Spacer()
                    // A badge only when there's something to say: no dot for idle.
                    if NeedsYou.shownState(role) != .ready { StatusBadge(kind: NeedsYou.shownState(role).kind) }
                }
                Text(role.name).font(AppFont.headline())
                Text(detail)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if NeedsYou.shownState(role) == .working {
                RoundedRectangle(cornerRadius: CornerRadius.lg)
                    .strokeBorder(Color.brandBlue, lineWidth: 2)
                    .phaseAnimator([0.25, 1.0]) { content, phase in
                        content.opacity(reduceMotion ? 0.6 : phase)
                    } animation: { _ in .easeInOut(duration: 1.0) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(role.name)")
    }

    private var detail: String {
        switch NeedsYou.shownState(role) {
        case .working: role.currentTask?.title ?? "Working."
        case .needsYou: "Waiting on your answer."
        case .ready: role.instructions.isEmpty ? "Ready for work." : role.instructions
        }
    }

    private var tint: Color {
        switch NeedsYou.shownState(role) {
        case .needsYou: .brandOrange
        case .working: .brandBlue
        case .ready: .brandGreen
        }
    }
}

/// The bot's photo if it has one, else its animal character.
struct RoleAvatar: View {
    let role: Bot
    let tint: Color

    var body: some View {
        Group {
            if let data = role.avatarImageData, let image = Self.image(from: data) {
                image.resizable().scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
            } else {
                BotAvatarView(look: role.look, mood: AvatarMood(NeedsYou.shownState(role)), size: 36, blinkId: role.id)
            }
        }
        .accessibilityHidden(true)
    }

    private static func image(from data: Data) -> Image? {
        #if os(iOS)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }
}
