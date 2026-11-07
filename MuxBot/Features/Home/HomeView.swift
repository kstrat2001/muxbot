import SwiftUI

/// "Your roles": tiles grouped Needs you / Working / Ready, with the Radio
/// dock pinned to the bottom.
struct HomeView: View {
    @Environment(RoleStore.self) private var store
    @Environment(AppRouter.self) private var router

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                ForEach(MuxRole.Status.allCases, id: \.self) { status in
                    let roles = store.roles(with: status)
                    if !roles.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.md) {
                            SectionHeader(title: status.label, count: roles.count)
                            LazyVGrid(columns: columns, spacing: Spacing.md) {
                                ForEach(roles) { role in
                                    Button { router.navigate(to: .roleChat(role.id)) } label: {
                                        RoleTile(role: role)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Spacing.lg)
        }
        .navigationTitle("Your roles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New role", systemImage: "plus") { router.showNewRole = true }
            }
        }
        .safeAreaInset(edge: .bottom) { RadioDock() }
    }
}

struct RoleTile: View {
    let role: MuxRole

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Image(systemName: role.kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(role.name).font(AppFont.headline())
                Text(role.summary)
                    .font(AppFont.footnote())
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(role.name)")
    }

    private var tint: Color {
        switch role.status {
        case .needsYou: .brandOrange
        case .working: .brandBlue
        case .ready: .brandGreen
        }
    }
}
