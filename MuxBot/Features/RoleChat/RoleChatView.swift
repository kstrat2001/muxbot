import SwiftUI
import SwiftData

/// One role's thread. Read, and answer when the role needs you; new work
/// goes through the Radio dock, which follows navigation to this role.
struct RoleChatView: View {
    let roleId: UUID

    @Environment(\.modelContext) private var context
    @Environment(OnDeviceLLMService.self) private var llm
    @Query private var matches: [MuxRole]
    @State private var conversation: ChatConversation?
    @State private var service: ChatService?

    init(roleId: UUID) {
        self.roleId = roleId
        _matches = Query(filter: #Predicate<MuxRole> { $0.id == roleId })
    }

    var body: some View {
        let role = matches.first
        Group {
            if let role, let conversation, let service {
                ChatView(conversation: conversation, service: service,
                         showsInput: role.state == .needsYou, placeholder: "Answer \(role.name)",
                         onSent: { RoleStore(context: context).setState(.working, for: role) }) {
                    VStack(spacing: Spacing.sm) {
                        Label(role.state.label, systemImage: role.systemImage)
                            .font(AppFont.footnote(.semibold))
                            .foregroundStyle(.secondary)
                        if !role.modelName.isEmpty {
                            Text("Model: \(role.modelName)").font(AppFont.caption()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity)
                }
            } else if role == nil {
                EmptyStateView(systemImage: "questionmark.circle", title: "Bot not found", message: "It may have been removed.")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(role?.name ?? "Bot")
        .task {
            guard conversation == nil, let role else { return }
            let convo = ChatService.conversation(for: role.id, title: role.name, context: context)
            if (convo.messages ?? []).isEmpty {
                let hello = ChatMessage(role: .assistant, content: "Hi, I'm \(role.name). \(role.instructions)")
                hello.conversation = convo
                context.insert(hello)
                try? context.save()
            }
            conversation = convo
            service = ChatService(llm: llm, instructions: "You are \(role.name), a darkmux bot. \(role.instructions)")
        }
    }
}
