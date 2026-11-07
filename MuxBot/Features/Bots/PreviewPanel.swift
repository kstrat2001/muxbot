import SwiftUI
import WebKit

/// The bot's live preview: its dev server in a web view, hot-reloading as
/// the crew edits. Today the URL is a temporary tailnet test server;
/// darkmux will report each run's own.
struct PreviewPanel: View {
    let url: URL
    let close: () -> Void

    @Environment(PreviewController.self) private var preview
    @Environment(AppRouter.self) private var router
    @State private var copiedNote: String?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "safari").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(url.host() ?? url.absoluteString)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("Copy visible preview", systemImage: "rectangle.dashed") { copy(visible: true) }
                    Button("Copy picked element", systemImage: "scope") { copy(visible: false) }
                        .disabled(preview.pickedCrop == nil)
                } label: {
                    Label("Copy screenshot", systemImage: "camera")
                } primaryAction: {
                    copy(visible: true)
                }
                .labelStyle(.iconOnly)
                .fixedSize()
                .help("Copy a screenshot of the preview to the clipboard")
                Button(preview.isPicking ? "Cancel" : "Pick", systemImage: preview.isPicking ? "xmark" : "scope") {
                    preview.togglePicking()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Point at part of the page; your next message is about it.")
                #if os(iOS)
                if sizeClass == .compact {
                    Button(router.previewFullScreen ? "Show chat" : "Full screen",
                           systemImage: router.previewFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        router.previewFullScreen.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                #endif
                Button("Close preview", systemImage: "xmark.circle.fill", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(.bar)
            WebView(preview.page)
                .overlay(alignment: .top) {
                    if let copiedNote {
                        Text(copiedNote)
                            .font(AppFont.caption(.semibold))
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xs)
                            .background(Capsule().fill(.regularMaterial))
                            .padding(.top, Spacing.sm)
                            .transition(.opacity)
                    }
                }
        }
        .task(id: url) { preview.show(url) }
    }

    private func copy(visible: Bool) {
        Task {
            let png = visible ? await preview.visiblePNG() : preview.pickedCrop
            let ok = png.map(Clipboard.copyPNG) ?? false
            withAnimation { copiedNote = ok ? "Copied" : "Couldn't copy" }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copiedNote = nil }
        }
    }
}
