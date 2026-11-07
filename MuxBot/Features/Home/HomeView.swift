import SwiftUI
import SwiftData

/// "Your bots": the lead bot on top, then bot tiles grouped Needs you /
/// Working / Ready from stored state. The bar at the bottom talks to the lead bot.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(FleetConnection.self) private var connection
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Bot.createdAt) private var roles: [Bot]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Button { router.navigate(to: .lead) } label: { LeadBotCard() }
                    .buttonStyle(.plain)
                ForEach(BotState.allCases, id: \.self) { state in
                    let group = roles.filter { $0.state == state }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            if state != .ready { HStack(spacing: Spacing.sm) {
                                StatusBadge(kind: state.kind)
                                Text("\(group.count)")
                                    .font(AppFont.caption(.semibold))
                                    .foregroundStyle(.secondary)
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
                if roles.isEmpty {
                    EmptyStateView(systemImage: "person.3", title: "No bots yet",
                                   message: "A bot is a project or theme you name, like your website. Tap + to add one, or ask \(LeadBot.name) to set one up.")
                    Button("Add an example bot", systemImage: "sparkles") { BotStore(context: modelContext).addExample() }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(Spacing.lg)
        }
        .navigationTitle("Your bots")
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
                Button("New bot", systemImage: "plus") { router.showNewBot = true }
            }
        }
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
                    if role.state != .ready { StatusBadge(kind: role.state.kind) }
                }
                Text(role.name).font(AppFont.headline())
                Text(detail)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if role.state == .working {
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
        switch role.state {
        case .working: role.currentTask?.title ?? "Working."
        case .needsYou: "Waiting on your answer."
        case .ready: role.instructions.isEmpty ? "Ready for work." : role.instructions
        }
    }

    private var tint: Color {
        switch role.state {
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
                BotAvatarView(look: role.look, mood: AvatarMood(role.state), size: 36, blinkId: role.id)
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

/// The lead bot's card: its latest line, tap to open the full thread.
struct LeadBotCard: View {
    @Query(filter: #Predicate<ChatConversation> { $0.roleId == nil }) private var threads: [ChatConversation]

    private var latest: String {
        let messages = (threads.first?.messages ?? []).filter { $0.role == .assistant }
        return messages.max { $0.timestamp < $1.timestamp }?.content
            ?? "Tell me what needs doing and I'll get the right bot on it."
    }

    var body: some View {
        CardView {
            HStack(alignment: .top, spacing: Spacing.md) {
                BotAvatarView(look: .lead, size: 44)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(LeadBot.name).font(AppFont.headline())
                    Text(latest)
                        .font(AppFont.subheadline())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens your conversation with \(LeadBot.name)")
    }
}
