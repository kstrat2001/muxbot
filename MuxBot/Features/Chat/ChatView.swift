import SwiftUI

/// A thread's transcript. Input lives in the shared `BotBar`, which follows
/// navigation, so this view only shows messages.
struct ChatView: View {
    let conversation: ChatConversation
    var isThinking = false

    private var messages: [ChatMessage] {
        (conversation.messages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.sm) {
                    ForEach(messages) { message in
                        ChatBubbleView(role: message.role, content: message.content).id(message.id)
                    }
                    if isThinking {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Spacing.lg)
            }
            .onChange(of: messages.count) {
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}
