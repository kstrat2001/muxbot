import SwiftUI
import SwiftData

/// Generic chat transcript. With `showsInput` it adds an input bar; role
/// chats pass `false` because work only starts through Radio.
struct ChatView<Footer: View>: View {
    let conversation: ChatConversation
    let service: ChatService
    var showsInput = true
    var placeholder = "Message"
    var onSent: (() -> Void)? = nil
    @ViewBuilder var footer: () -> Footer

    @Environment(\.modelContext) private var context
    @State private var draft = ""

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
                    if service.isResponding {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Spacing.lg)
            }
            .onChange(of: messages.count) {
                if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                footer()
                if showsInput { inputBar }
            }
            .background(.bar)
        }
    }

    private var inputBar: some View {
        HStack(spacing: Spacing.sm) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(send)
            Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                .labelStyle(.iconOnly)
                .font(.title2)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || service.isResponding)
        }
        .padding(Spacing.md)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        onSent?()
        Task { await service.send(text, in: conversation, context: context) }
    }
}

extension ChatView where Footer == EmptyView {
    init(conversation: ChatConversation, service: ChatService, showsInput: Bool = true, placeholder: String = "Message") {
        self.init(conversation: conversation, service: service, showsInput: showsInput, placeholder: placeholder) { EmptyView() }
    }
}
