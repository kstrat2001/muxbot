import Foundation
import SwiftData

/// Reads and writes roles in the app's SwiftData store. Views read live
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

    /// Records a task on the role and sets it Working. No fleet call yet.
    @discardableResult
    func assign(task title: String, why: String, to role: MuxRole) -> RoleTask {
        let task = RoleTask(title: title, why: why)
        context.insert(task)
        task.role = role
        role.state = RoleState.working

        let convo = ChatService.conversation(for: role.id, title: role.name, context: context)
        let note = ChatMessage(role: .system, content: "New task from Radio: \(title)\nWhy: \(why)")
        note.conversation = convo
        context.insert(note)
        try? context.save()
        return task
    }

    func setState(_ state: RoleState, for role: MuxRole) {
        role.state = state
        try? context.save()
    }
}
