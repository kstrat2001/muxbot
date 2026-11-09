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
            .task(id: displayScale) { preview.displayScale = displayScale }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottomTrailing) { controls }
            .task(id: url) { preview.show(url) }
            .onChange(of: preview.picked) {
                if preview.picked != nil { router.returnToChatAfterPick() }
            }
    }

    private var controls: some View {
        HStack(spacing: Spacing.md) {
            if let bot, NeedsYou.shownState(bot) != .ready {
                StatusBadge(kind: NeedsYou.shownState(bot).kind)
            }
            Button(preview.isPicking ? "Cancel pick" : "Pick", systemImage: preview.isPicking ? "xmark" : "scope") {
                preview.togglePicking()
            }
            Button(copied ? "Copied" : "Copy screenshot", systemImage: copied ? "checkmark" : "camera") {
                Task {
                    if let png = await preview.visiblePNG() { copied = Clipboard.copyImage(png) }
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            Button("Back to chat", systemImage: "bubble.left.and.bubble.right.fill") {
                router.showPreview = false
            }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Capsule().fill(.regularMaterial))
        .padding(Spacing.md)
    }
}
#endif
