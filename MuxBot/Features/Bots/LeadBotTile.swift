import SwiftUI

/// What the sidebar shows, top to bottom: Mux Bot featured on its own,
/// then your bots, then Activity.
enum SidebarLayout {
    enum Section: Equatable {
        case featured(SidebarItem)
        case bots([SidebarItem])
        case activity
    }

    static func sections(bots: [UUID]) -> [Section] {
        [.featured(.lead), .bots(bots.map(SidebarItem.bot)), .activity]
    }
}

/// Mux Bot, the guide, featured above the bots: a large face with its name
/// under it, centered. No badge or star; its unread dot when it has news.
struct LeadBotTile: View {
    var selected = false
    var unread = false

    static let accessibilityName = String(localized: "Mux Bot, your guide")

    #if os(macOS)
    static let avatarSize: CGFloat = 84
    #else
    static let avatarSize: CGFloat = 92
    #endif

    var body: some View {
        VStack(spacing: Spacing.sm) {
            BotAvatarView(look: .lead, size: Self.avatarSize)
            HStack(spacing: Spacing.xs) {
                Text(LeadBot.name).font(AppFont.headline())
                if unread {
                    Circle().fill(Color.brandBlue).frame(width: 8, height: 8)
                }
            }
        }
        // A compact card, centered: the guide stands apart from the list.
        .frame(minWidth: Self.avatarSize + 56)
        .padding(.vertical, Spacing.md)
        .padding(.horizontal, Spacing.lg)
        .background(RoundedRectangle(cornerRadius: CornerRadius.lg)
            .fill(selected ? Color.brandBlue.opacity(0.18) : Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.lg)
            .strokeBorder(selected ? Color.brandBlue : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityName)
        .accessibilityValue(unread ? String(localized: "Unread") : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
