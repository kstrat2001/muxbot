import SwiftUI

/// Bottom dock: the latest update line plus the mic button. Both open Radio.
struct RadioDock: View {
    @Environment(RoleStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        HStack(spacing: Spacing.md) {
            Button { router.openRadio() } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(Color.brandGreen)
                        .accessibilityHidden(true)
                    Text(store.latestUpdate)
                        .font(AppFont.subheadline())
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Radio. Latest: \(store.latestUpdate)")

            Button { router.openRadio() } label: {
                Image(systemName: "mic.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.brandGreenAccessible))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Talk to Radio")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(.bar)
    }
}
