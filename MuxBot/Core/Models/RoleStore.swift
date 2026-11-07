import Foundation
import SwiftData

/// Reads and writes bots (roles in code) and their threads in the app's SwiftData store. Views read live
/// with `@Query`; every mutation goes through here.
@MainActor
struct RoleStore {
    let context: ModelContext

    nonisolated static let defaults: [(name: String, systemImage: String, instructions: String)] = [
        ("Coder", "hammer", "Writes and changes code: implement features, fix bugs, refactor, build."),
        ("Reviewer", "magnifyingglass", "Reviews code and pull requests: check diffs, find problems, audit changes."),
        ("Eval runner", "gauge", "Runs evals and benchmarks: measure performance, test models, compare scores."),
        ("Researcher", "lightbulb", "Researches questions: read papers and docs, investigate, compare options, summarize."),
    ]

    func allRoles() -> [MuxRole] {
        let descriptor = FetchDescriptor<MuxRole>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func role(id: UUID) -> MuxRole? {
        allRoles().first { $0.id == id }
    }

    /// Inserts the four starter roles on first launch only.
    func seedIfEmpty() {
        guard allRoles().isEmpty else { return }
        let start = Date()
        for (offset, item) in Self.defaults.enumerated() {
            let role = MuxRole(name: item.name, instructions: item.instructions, systemImage: item.systemImage)
            role.createdAt = start.addingTimeInterval(Double(offset))
            context.insert(role)
        }
        try? context.save()
    }

    @discardableResult
    func add(name: String, instructions: String, modelName: String, systemImage: String = "sparkles") -> MuxRole {
        let role = MuxRole(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            systemImage: systemImage
        )
        context.insert(role)
        try? context.save()
        return role
    }

    /// Records work handed to a bot, sets it Working, and posts the
    /// handoff in the bot's thread. No fleet call yet.
    @discardableResult
    func handOff(task title: String, from sender: String, to role: MuxRole) -> RoleTask {
        let task = RoleTask(title: title, why: "From \(sender)")
        context.insert(task)
        task.role = role
        role.state = RoleState.working
        append(.system, "From \(sender): \(title)", to: conversation(for: .bot(role.id)))
        return task
    }

    /// The thread for a context, created on first use. The lead bot's
    /// thread has no role id.
    func conversation(for chat: ChatContext) -> ChatConversation {
        let roleId = chat.botId
        let all = (try? context.fetch(FetchDescriptor<ChatConversation>())) ?? []
        if let existing = all.first(where: { $0.roleId == roleId }) { return existing }
        let title = roleId.flatMap { role(id: $0)?.name } ?? LeadBot.name
        let created = ChatConversation(title: title, roleId: roleId)
        context.insert(created)
        try? context.save()
        return created
    }

    func append(_ role: ChatRole, _ text: String, to conversation: ChatConversation) {
        let message = ChatMessage(role: role, content: text)
        message.conversation = conversation
        context.insert(message)
        conversation.updatedAt = .now
        try? context.save()
    }

    func setState(_ state: RoleState, for role: MuxRole) {
        role.state = state
        try? context.save()
    }
}
