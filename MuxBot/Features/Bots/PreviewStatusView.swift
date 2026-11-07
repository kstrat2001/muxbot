import SwiftUI

/// Where the preview panel goes while darkmux starts the preview, or why it
/// didn't start.
struct PreviewStatusView: View {
    let preview: LivePreview
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.md) {
            switch preview.status {
            case .starting, .installing:
                ProgressView()
                Text(preview.status.text).foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Color.brandOrange)
                Text(preview.status.text).multilineTextAlignment(.center)
                if let log = preview.log, !log.isEmpty {
                    ScrollView {
                        Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(Spacing.sm)
                    .background(RoundedRectangle(cornerRadius: CornerRadius.md).fill(Color.cardBackground))
                }
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
            case .ready, .stopped:
                Text(preview.status.text).foregroundStyle(.secondary)
                Button("Start", systemImage: "play", action: retry)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
