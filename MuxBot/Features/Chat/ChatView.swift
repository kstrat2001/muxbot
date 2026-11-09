import SwiftUI
import SwiftData

/// A thread's transcript, Messages-style: newest at the bottom, bot on the
/// left, you on the right, run cards inline. The thread view pins `BotBar`
/// under it.
struct ChatView: View {
    let conversation: ChatConversation
    var isThinking = false

    @Environment(AppRouter.self) private var router
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
                            } else if message.kind == .bugCard {
                                BugCardView(message: message)
                            } else if message.kind == .actionCard {
                                ActionCardView(message: message)
                            } else if message.kind == .guideCard {
                                GuideCardView(message: message, isLatest: message.id == latestSetupId)
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
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                focus(proxy)
            }
            .onChange(of: router.focusRunId) { focus(proxy) }
        }
    }

    /// Scrolls to the focused run's newest card and outlines it briefly.
    private func focus(_ proxy: ScrollViewProxy) {
        guard let runId = router.focusRunId,
              let card = messages.last(where: { $0.runId == runId }) else { return }
        router.focusRunId = nil
        withAnimation { proxy.scrollTo(card.id, anchor: .center) }
        flashRunId = runId
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut) { flashRunId = nil }
        }
    }
}
