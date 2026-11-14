import SwiftUI
import SwiftData

/// A thread's transcript, Messages-style: newest at the bottom, bot on the
/// left, you on the right, run cards inline. The thread view pins `BotBar`
/// under it.
struct ChatView: View {
    let conversation: ChatConversation
    var isThinking = false

    @Environment(AppRouter.self) private var router
    @Environment(BotBrain.self) private var brain
    @Query private var bots: [Bot]

    /// The thread's bot's first GitHub repo, for linking "#8".
    private var repo: String? {
        bots.first { $0.id == conversation.roleId }?.repoSlugs.first
    }
    @State private var flashRunId: UUID?
    /// Following the newest message: true until you scroll up, and again
    /// once you're back at the bottom. While it's true, anything that makes
    /// the transcript taller (a new message, a card that grows as it loads,
    /// the shelf above the chat bar) keeps the bottom in view.
    @State private var pinned = true

    /// Where the bottom of the transcript is, for following it.
    private static let bottomId = "chat-bottom"

    private var messages: [ChatMessage] {
        (conversation.messages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    /// The newest setup check: the only one that keeps looking.
    private var latestSetupId: UUID? {
        messages.last { $0.guideCard == .setup }?.id
    }

    /// The newest next-steps card: the only one whose steps can be tapped.
    private var latestNextStepsId: UUID? {
        messages.last { if case .nextSteps? = $0.guideCard { true } else { false } }?.id
    }

    /// The newest card of each kind for each run; older ones are history.
    private var latestCardIds: Set<UUID> {
        var latest: [String: ChatMessage] = [:]
        for message in messages where message.runId != nil {
            latest["\(message.runId?.uuidString ?? "")-\(message.kind.rawValue)"] = message
        }
        return Set(latest.values.map(\.id))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: Spacing.sm) {
                        ForEach(messages) { message in
                            Group {
                                if message.kind == .text {
                                    ChatBubbleView(role: message.role, content: message.content, repo: repo)
                                    if let details = brain.runs.messageDetails[message.id] {
                                        TechnicalDetails(text: details).chatColumn(alignment: .leading)
                                    }
                                } else if message.kind == .bugCard {
                                    BugCardView(message: message)
                                } else if message.kind == .actionCard {
                                    ActionCardView(message: message)
                                } else if message.kind == .guideCard {
                                    GuideCardView(message: message, isLatest: message.id == latestSetupId || message.id == latestNextStepsId)
                                } else {
                                    RunCardView(message: message, isLatest: latestCardIds.contains(message.id))
                                        .overlay {
                                            if flashRunId != nil, message.runId == flashRunId, latestCardIds.contains(message.id) {
                                                RoundedRectangle(cornerRadius: CornerRadius.lg)
                                                    .stroke(Color.brandOrange, lineWidth: 2)
                                                    .chatColumn(alignment: .leading)
                                                    .allowsHitTesting(false)
                                            }
                                        }
                                }
                            }
                            .id(message.id)
                        }
                        if isThinking {
                            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(Spacing.lg)
                    Color.clear.frame(height: 1).id(Self.bottomId)
                }
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: ScrollMetrics.self) { ScrollMetrics($0) } action: { old, new in
                if new.layoutDiffers(from: old) {
                    // Taller content or a smaller window: stay on the newest.
                    if pinned { scrollToBottom(proxy) }
                } else {
                    // You scrolled: follow again only once at the bottom.
                    pinned = new.distanceFromBottom < 40
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !pinned {
                    Button {
                        pinned = true
                        withAnimation { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().stroke(.separator, lineWidth: 0.5))
                            .shadow(radius: 2, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("Jump to latest")
                    .accessibilityLabel("Jump to latest")
                    .padding(Spacing.lg)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: pinned)
            .onChange(of: messages.count) {
                // A new message brings you to it, like Messages.
                pinned = true
                scrollToBottom(proxy)
                // A message asked for before it arrived (a card just posted).
                focusMessage(proxy)
            }
            .onAppear {
                scrollToBottom(proxy)
                focus(proxy)
                focusMessage(proxy)
            }
            .onChange(of: router.focusRunId) { focus(proxy) }
            .onChange(of: router.focusMessageId) { focusMessage(proxy) }
        }
    }

    /// Without animation, so no in-between position reads as you scrolling
    /// away; a card that keeps growing is followed on the next change.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomId, anchor: .bottom)
    }

    /// A Search result: scrolls to its message, once it's in this thread.
    private func focusMessage(_ proxy: ScrollViewProxy) {
        guard let id = router.focusMessageId, messages.contains(where: { $0.id == id }) else { return }
        router.focusMessageId = nil
        withAnimation { proxy.scrollTo(id, anchor: .center) }
    }

    /// Scrolls to the focused run's newest card and outlines it briefly.
    private func focus(_ proxy: ScrollViewProxy) {
        guard let runId = router.focusRunId else { return }
        // Cleared even when its card is gone, so it never fires later.
        router.focusRunId = nil
        guard let card = messages.last(where: { $0.runId == runId }) else { return }
        withAnimation { proxy.scrollTo(card.id, anchor: .center) }
        flashRunId = runId
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut) { flashRunId = nil }
        }
    }
}

/// What following the bottom needs from the scroll view: the content's
/// height and the visible height (they change with the content and the
/// window, not with your scrolling), and how far the bottom is out of view.
struct ScrollMetrics: Equatable {
    var contentHeight: CGFloat
    var visibleHeight: CGFloat
    var distanceFromBottom: CGFloat

    init(contentHeight: CGFloat, visibleHeight: CGFloat, distanceFromBottom: CGFloat) {
        self.contentHeight = contentHeight
        self.visibleHeight = visibleHeight
        self.distanceFromBottom = distanceFromBottom
    }

    init(_ geometry: ScrollGeometry) {
        let visible = geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
        // The bottom of what you see, in content coordinates.
        let seenTo = geometry.contentOffset.y + geometry.contentInsets.top + visible
        self.init(contentHeight: geometry.contentSize.height,
                  visibleHeight: visible,
                  distanceFromBottom: max(0, geometry.contentSize.height - seenTo))
    }

    /// The content or the window changed size, not where you scrolled to.
    func layoutDiffers(from other: ScrollMetrics) -> Bool {
        abs(contentHeight - other.contentHeight) > 0.5 || abs(visibleHeight - other.visibleHeight) > 0.5
    }
}
