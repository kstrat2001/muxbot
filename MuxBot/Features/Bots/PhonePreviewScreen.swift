#if os(iOS)
import SwiftUI
import WebKit

/// iPhone and iPad: the preview fills the screen at the device's own width,
/// as in its browser. A small floating control goes back to the chat and
/// shows the bot's status; Pick and the selection menu work here, and a
/// pick returns to the chat with the element chip attached.
struct PhonePreviewScreen: View {
    let url: URL
    let bot: Bot?

    @Environment(PreviewController.self) private var preview
    @Environment(AppRouter.self) private var router
    /// Copies are made at this screen's scale.
    @Environment(\.displayScale) private var displayScale
    @State private var copied = false

    var body: some View {
        WebView(preview.page)
            .onChange(of: preview.picked) { _, picked in if picked != nil { router.focusBarRequest += 1 } }
            .webViewBackForwardNavigationGestures(.disabled)
            .task(id: displayScale) { preview.displayScale = displayScale }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottomTrailing) { controls }
            .task(id: url) { preview.showFullScreen(url, for: bot?.id) }
            .onChange(of: preview.picked) {
                if preview.picked != nil { router.returnToChatAfterPick() }
            }
    }

    private var controls: some View {
        HStack(spacing: Spacing.md) {
            if let bot, NeedsYou.shownState(bot) != .ready {
                StatusBadge(kind: NeedsYou.shownState(bot).kind)
            }
            Button("Reload", systemImage: "arrow.clockwise") { preview.goHome() }
            Button(preview.isPicking ? "Cancel" : "Pick", systemImage: preview.isPicking ? "xmark" : "scope") {
                preview.togglePicking()
            }
            .accessibilityLabel(preview.isPicking ? "Cancel pick" : "Pick")
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "camera") {
                Task {
                    if let png = await preview.visiblePNG() { copied = Clipboard.copyImage(png) }
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            .accessibilityLabel(copied ? "Copied" : "Copy screenshot")
            Button("Chat", systemImage: "bubble.left.and.bubble.right.fill") {
                router.showPreview = false
            }
            .accessibilityLabel("Back to chat")
        }
        // A short word under each icon, like a tab bar.
        .labelStyle(IconOverTitleLabelStyle())
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Capsule().fill(.regularMaterial))
        .padding(Spacing.md)
    }
}

/// An icon with a short word under it (the full-screen preview's controls).
struct IconOverTitleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 2) {
            configuration.icon.font(.title3)
            configuration.title.font(.caption2)
        }
        .frame(minWidth: 44, minHeight: 44)
    }
}
#endif
