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
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) {
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                // A message asked for before it arrived (a card just posted).
                focusMessage(proxy)
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                focus(proxy)
                focusMessage(proxy)
            }
            .onChange(of: router.focusRunId) { focus(proxy) }
            .onChange(of: router.focusMessageId) { focusMessage(proxy) }
        }
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
