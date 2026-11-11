import SwiftUI
import WebKit

/// The bot's live preview: its dev server in a web view, hot-reloading as
/// the crew edits. Today the URL is a temporary tailnet test server;
/// darkmux will report each run's own.
struct PreviewPanel: View {
    let url: URL
    var recipeViewports: [String]? = nil
    /// The bot whose preview this is: its device size is remembered on this
    /// Mac (`LocalBotState`), across page changes, threads and relaunches.
    var botId: UUID? = nil
    let close: () -> Void

    /// Only without a bot; a bot's choice lives in `LocalBotState`.
    @State private var viewport: PreviewViewport?
    @State private var settled: PreviewViewport.Layout?
    @State private var settleTask: Task<Void, Never>?

    @Environment(PreviewController.self) private var preview
    @Environment(AppRouter.self) private var router
    @Environment(BotBrain.self) private var brain
    @Environment(\.modelContext) private var context
    /// Copies are made at this screen's scale.
    @Environment(\.displayScale) private var displayScale
    @State private var copiedNote: String?
    /// The camera shows a checkmark for a moment after a copy.
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "safari").foregroundStyle(Color.secondaryText).accessibilityHidden(true)
                // What the page actually shows (it may have moved on from the
                // preview's address).
                Text(preview.page.url?.host() ?? url.host() ?? url.absoluteString)
                    .font(AppFont.caption())
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                Spacer()
                Button("Reload the preview", systemImage: "arrow.clockwise") { preview.goHome() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Load the preview's own page again")
                // One button: a screenshot of what the preview shows. (A picked
                // element already rides along with your message as a chip.)
                Button(copied ? "Copied" : "Copy the visible preview", systemImage: copied ? "checkmark" : "camera") { copyVisible() }
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
                    .help(copied ? "Copied" : "Copy the visible preview")
                Button(preview.isPicking ? "Cancel" : "Pick", systemImage: preview.isPicking ? "xmark" : "scope") {
                    preview.togglePicking()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Point at part of the page; your next message is about it.")
                Menu {
                    ForEach(PreviewViewport.allCases, id: \.self) { option in
                        Button(option.label, systemImage: option.systemImage) { choose(option) }
                    }
                    // "Something's off": reinstall the packages and start again.
                    if brain.runs.canStartOver, let bot = startOverBot {
                        Divider()
                        Button("Start over", systemImage: "arrow.counterclockwise") {
                            Task { await brain.runs.startOver(for: bot) }
                        }
                        .help(PreviewFailure.startOverNote)
                    }
                } label: {
                    Label(currentViewport.label, systemImage: currentViewport.systemImage)
                }
                .labelStyle(.iconOnly)
                .fixedSize()
                .help("Preview at phone, tablet or desktop width")
                Button(router.previewFullScreen ? "Show chat" : "Full window",
                       systemImage: router.previewFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    router.previewFullScreen.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(router.previewFullScreen ? .cancelAction : KeyboardShortcut("f", modifiers: [.command, .shift]))
                .help(router.previewFullScreen ? "Back to chat (Esc)" : "Preview fills the window (⇧⌘F)")
                Button("Close preview", systemImage: "xmark.circle.fill", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(.bar)
            GeometryReader { geometry in
                // Device widths: hold the last scale while the panel is being
                // resized and apply the new one once it settles, so the page
                // isn't re-laid out on every frame (that flickered).
                let layout = currentViewport.shown(settled: settled, in: geometry.size)
                WebView(preview.page)
                    .webViewBackForwardNavigationGestures(.disabled)
                    .task(id: displayScale) { preview.displayScale = displayScale }
                    .modifier(DeviceFrame(layout: layout, panel: geometry.size))
                    .onChange(of: geometry.size) { settle(for: geometry.size) }
                    .onChange(of: currentViewport) { settled = currentViewport.layout(in: geometry.size) }
                    .onAppear { settled = currentViewport.layout(in: geometry.size) }
                    #if os(macOS)
                    // Opening, another bot or another device size: the pane takes
                    // the width you set, else fits the page. Double-click the
                    // divider to fit it again; the width you leave it at is kept.
                    .background(SplitDividerDoubleClick(
                        key: "\(botId?.uuidString ?? "")-\(currentViewport.rawValue)-\(router.previewFullScreen)",
                        paneWidth: currentViewport.openingPaneWidth(stored: botId.flatMap { LocalBotState.shared[$0]?.previewPaneWidth },
                                                                    panelHeight: geometry.size.height),
                        fitWidth: currentViewport.fittedPanelWidth(panelHeight: geometry.size.height),
                        resized: { width in
                            guard let botId else { return }
                            LocalBotState.shared.update(botId) { $0.previewPaneWidth = Double(width) }
                        }))
                    #endif
            }
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
        .task(id: url) { preview.show(url, for: botId, generation: botId.flatMap { brain.runs.previewReloads[$0] } ?? 0) }
        // A pick (or Chat about this) puts the cursor in the bar for your words.
        .onChange(of: preview.picked) { _, picked in if picked != nil { router.focusBarRequest += 1 } }
        .task { await brain.runs.checkStartOver() }
        // Edit on a selection: the words in a focused editor; Save changes the file.
        .sheet(isPresented: Binding(get: { preview.editing != nil && preview.editingBot == botId },
                                    set: { if !$0 { preview.endEditing() } })) {
            if let element = preview.editing {
                HandEditSheet(element: element, crop: preview.editingCrop, save: { new in
                    let bot = botId.flatMap { BotStore(context: context).bot(id: $0) }
                    preview.endEditing()
                    guard let bot else { return }
                    Task { await brain.runs.handEdit(element, to: new, bot: bot, store: BotStore(context: context)) }
                }, cancel: { preview.endEditing() })
            }
        }
        // A run changed files (or Undo): show what the server serves now.
        .onChange(of: botId.flatMap { brain.runs.previewReloads[$0] }) { _, count in preview.show(url, for: botId, generation: count ?? 0) }
    }

    /// The bot whose darkmux preview this is (Start over needs its workspace).
    private var startOverBot: Bot? {
        botId.flatMap { BotStore(context: context).bot(id: $0) }.flatMap { $0.workspaceName == nil ? nil : $0 }
    }

    private func settle(for size: CGSize) {
        guard currentViewport.width != nil else {
            settled = nil   // Fit follows the panel live, like any web view
            return
        }
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            settled = currentViewport.layout(in: size)
        }
    }

    private var currentViewport: PreviewViewport {
        #if DEBUG
        // `-previewViewport desktop` for layout checks.
        if viewport == nil, let forced = UserDefaults.standard.string(forKey: "previewViewport").flatMap(PreviewViewport.init(rawValue:)) {
            return forced
        }
        #endif
        return viewport ?? PreviewViewport.resolve(stored: botId.flatMap { LocalBotState.shared[$0]?.previewViewport },
                                                   recipe: recipeViewports)
    }

    private func choose(_ option: PreviewViewport) {
        if let botId {
            // A new device size fits the pane to it afresh.
            LocalBotState.shared.update(botId) { $0.previewViewport = option.rawValue; $0.previewPaneWidth = nil }
        } else {
            viewport = option
        }
    }

    private func copyVisible() {
        Task {
            let ok = await preview.visiblePNG().map(Clipboard.copyImage) ?? false
            withAnimation {
                if ok { copied = true } else { copiedNote = "Couldn't copy the preview" }
            }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false; copiedNote = nil }
        }
    }
}

/// Lays a page out at `layout`'s size and scale inside a panel: a device is
/// centered in a rounded frame with a hairline edge; Desktop and Fit fill
/// the panel from its corner.
struct DeviceFrame: ViewModifier {
    let layout: PreviewViewport.Layout
    let panel: CGSize

    func body(content: Content) -> some View {
        let origin = layout.origin(in: panel)
        let corner: CGFloat = layout.framed ? 18 : 0
        content
            .frame(width: layout.width, height: layout.height)
            .scaleEffect(layout.scale, anchor: .topLeading)
            .frame(width: layout.width * layout.scale, height: layout.height * layout.scale, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                if layout.framed {
                    RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.quaternary, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(layout.framed ? 0.12 : 0), radius: 10, y: 3)
            .offset(x: origin.x, y: origin.y)
            .frame(width: panel.width, height: panel.height, alignment: .topLeading)
            .background(layout.framed ? Color.secondary.opacity(0.06) : Color.clear)
            .clipped()
    }
}
