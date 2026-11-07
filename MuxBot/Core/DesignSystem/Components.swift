import SwiftUI

struct CardView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(Spacing.lg)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.lg))
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack {
            Text(title).font(AppFont.headline())
            if let count {
                Text("\(count)")
                    .font(AppFont.caption(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(AppFont.title2())
            Text(message)
                .font(AppFont.body())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status

/// Every status the app shows. Shown with icons and motion, not words; the
/// words live only in the accessibility label.
enum StatusKind {
    case running, queued, needsYou, done, failed, idle

    var accessibilityLabel: String {
        switch self {
        case .running: "Running"
        case .queued: "Queued"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .failed: "Failed"
        case .idle: "Ready"
        }
    }
}

extension RunStatus {
    var kind: StatusKind {
        switch self {
        case .running: .running
        case .queued: .queued
        case .needsYou: .needsYou
        case .done: .done
        case .failed: .failed
        }
    }
}

extension BotState {
    var kind: StatusKind {
        switch self {
        case .needsYou: .needsYou
        case .working: .running
        case .ready: .idle
        }
    }
}

/// The one status indicator: run rows, group headers, bot tiles, threads.
struct StatusBadge: View {
    let kind: StatusKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        icon
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.accessibilityLabel)
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .running:
            if reduceMotion {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.brandBlue)
            } else {
                ProgressView().controlSize(.small)
            }
        case .queued:
            Image(systemName: "hourglass")
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, isActive: !reduceMotion)
        case .needsYou:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .symbolEffect(.pulse, isActive: !reduceMotion)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brandGreen)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.brandRed)
        case .idle:
            Circle().fill(.secondary.opacity(0.4)).frame(width: 8, height: 8)
        }
    }
}
