import SwiftUI
import SwiftData

/// One role's thread. No task input: new work goes through Radio.
struct RoleChatView: View {
    let roleId: UUID

    @Environment(\.modelContext) private var context
    @Environment(RoleStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(OnDeviceLLMService.self) private var llm
    @State private var conversation: ChatConversation?
    @State private var service: ChatService?

    var body: some View {
        let role = store.role(id: roleId)
        Group {
            if let role, let conversation, let service {
                ChatView(conversation: conversation, service: service, showsInput: false) {
                    VStack(spacing: Spacing.sm) {
                        Label(role.status.label, systemImage: role.kind.systemImage)
                            .font(AppFont.footnote(.semibold))
                            .foregroundStyle(.secondary)
                        Text(role.summary).font(AppFont.subheadline())
                        Button("New work? Ask Radio") { router.openRadio() }
                            .font(AppFont.subheadline(.semibold))
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity)
                }
            } else if role == nil {
                EmptyStateView(systemImage: "questionmark.circle", title: "Role not found", message: "It may have been removed.")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(role?.name ?? "Role")
        .task {
            guard conversation == nil, let role else { return }
            let convo = ChatService.conversation(for: role.id, title: role.name, context: context)
            if (convo.messages ?? []).isEmpty {
                let hello = ChatMessage(role: .assistant, content: "Hi, I'm \(role.name). \(role.summary)")
                hello.conversation = convo
                context.insert(hello)
                try? context.save()
            }
            conversation = convo
            service = ChatService(llm: llm, instructions: "You are \(role.name), a darkmux role.")
        }
    }
}
