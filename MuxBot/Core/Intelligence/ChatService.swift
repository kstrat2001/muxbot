import Foundation
import SwiftData

/// Generic chat over a `ChatConversation`. Persists messages and gets a
/// reply. Placeholder: replies come from the on-device model (or a canned
/// line); darkmux is not called yet.
@MainActor @Observable
final class ChatService {
    var isResponding = false

    private let llm: OnDeviceLLMService
    private let instructions: String

    init(llm: OnDeviceLLMService, instructions: String) {
        self.llm = llm
        self.instructions = instructions
    }

    func send(_ text: String, in conversation: ChatConversation, context: ModelContext) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        append(.user, trimmed, to: conversation, context: context)
        isResponding = true
        defer { isResponding = false }

        let reply = await llm.respond(to: trimmed, instructions: instructions)
            ?? "Got it. (Placeholder reply: darkmux is not connected yet.)"
        append(.assistant, reply, to: conversation, context: context)
    }

    private func append(_ role: ChatRole, _ content: String, to conversation: ChatConversation, context: ModelContext) {
        let message = ChatMessage(role: role, content: content)
        message.conversation = conversation
        context.insert(message)
        conversation.updatedAt = .now
        try? context.save()
    }

    /// Finds or creates the conversation for a role (`nil` = Radio).
    static func conversation(for roleId: UUID?, title: String, context: ModelContext) -> ChatConversation {
        let all = (try? context.fetch(FetchDescriptor<ChatConversation>())) ?? []
        if let existing = all.first(where: { $0.roleId == roleId }) { return existing }
        let created = ChatConversation(title: title, roleId: roleId)
        context.insert(created)
        try? context.save()
        return created
    }
}
