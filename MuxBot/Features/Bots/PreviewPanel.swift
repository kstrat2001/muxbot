import SwiftUI
import WebKit

/// The bot's live preview: its dev server in a web view, hot-reloading as
/// the crew edits. Today the URL is a temporary tailnet test server;
/// darkmux will report each run's own.
struct PreviewPanel: View {
    let url: URL
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "safari").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(url.host() ?? url.absoluteString)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Close preview", systemImage: "xmark.circle.fill", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(.bar)
            WebView(url: url)
        }
    }
}
