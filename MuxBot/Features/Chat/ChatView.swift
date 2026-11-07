import SwiftUI

/// A thread's transcript, Messages-style: newest at the bottom, bot on the
/// left, you on the right, run cards inline. The thread view pins `BotBar`
/// under it.
struct ChatView: View {
    let conversation: ChatConversation
    var isThinking = false

    private var messages: [ChatMessage] {
        (conversation.messages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    /// The newest card of each kind for each run; older ones are history.
    private var latestCardIds: Set<UUID> {
        var latest: [String: ChatMessage] = [:]
        for message in messages where message.kind != .text {
            latest["\(message.runId?.uuidString ?? "")-\(message.kind.rawValue)"] = message
        }
        return Set(latest.values.map(\.id))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.sm) {
                    ForEach(messages) { message in
                        Group {
                            if message.kind == .text {
                                VStack(alignment: .trailing, spacing: Spacing.xs) {
                                    ChatBubbleView(role: message.role, content: message.content)
                                    if message.role == .user, message.conversation?.roleId != nil {
                                        IntentChip(message: message)
                                    }
                                }
                            } else if message.kind == .bugCard {
                                BugCardView(message: message)
                            } else {
                                RunCardView(message: message, isLatest: latestCardIds.contains(message.id))
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
            }
        }
    }
}
