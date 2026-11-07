import SwiftUI
import SwiftData

/// "Your bots": tiles grouped Needs you / Working / Ready from stored state,
/// with the Radio dock pinned to the bottom.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Query(sort: \MuxRole.createdAt) private var roles: [MuxRole]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                ForEach(RoleState.allCases, id: \.self) { state in
                    let group = roles.filter { $0.state == state }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            SectionHeader(title: state.label, count: group.count)
                            LazyVGrid(columns: columns, spacing: Spacing.md) {
                                ForEach(group) { role in
                                    Button { router.navigate(to: .roleChat(role.id)) } label: {
                                        RoleTile(role: role)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                if roles.isEmpty {
                    EmptyStateView(systemImage: "person.3", title: "No bots yet",
                                   message: "Tap + to add one, or ask Radio to draft one.")
                }
            }
            .padding(Spacing.lg)
        }
        .navigationTitle("Your bots")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New bot", systemImage: "plus") { router.showNewRole = true }
            }
        }
    }
}

struct RoleTile: View {
    let role: MuxRole

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                RoleAvatar(role: role, tint: tint)
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
        .accessibilityValue(role.state.label)
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

/// The role's avatar image if it has one, else its SF Symbol.
struct RoleAvatar: View {
    let role: MuxRole
    let tint: Color

    var body: some View {
        Group {
            if let data = role.avatarImageData, let image = Self.image(from: data) {
                image.resizable().scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
            } else {
                Image(systemName: role.systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: role.state == .working)
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
