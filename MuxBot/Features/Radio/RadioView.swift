import SwiftUI
import SwiftData

/// Radio: the one place work starts. Talk or type; Radio routes it to a role.
struct RadioView: View {
    @Environment(\.modelContext) private var context
    @Environment(OnDeviceLLMService.self) private var llm
    @State private var conversation: ChatConversation?
    @State private var service: ChatService?
    @State private var isListening = false

    var body: some View {
        Group {
            if let conversation, let service {
                ChatView(conversation: conversation, service: service, placeholder: "Tell Radio what you need") {
                    micButton
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Radio")
        .task {
            guard conversation == nil else { return }
            conversation = ChatService.conversation(for: nil, title: "Radio", context: context)
            service = ChatService(llm: llm, instructions: """
                You are Radio, the dispatcher in Mux Bot. You take the user's request \
                and say which darkmux role should do it. Be brief and friendly.
                """)
        }
    }

    /// Placeholder: speech input is not wired yet.
    private var micButton: some View {
        Button { isListening.toggle() } label: {
            Label(isListening ? "Listening… (placeholder)" : "Hold to talk",
                  systemImage: isListening ? "waveform" : "mic.fill")
                .font(AppFont.subheadline(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.sm)
    }
}
