import Foundation
import SwiftData

/// Reads and writes bots, their resources and their threads in the app's
/// SwiftData store. Views read live with `@Query`; every mutation goes through here.
@MainActor
struct BotStore {
    let context: ModelContext

    /// Starter bots: projects and themes, not roles. Edit or delete freely.
    nonisolated static let defaults: [(name: String, systemImage: String, instructions: String, resources: [(ResourceKind, String)])] = [
        ("humancodereader", "eyeglasses",
         "The humancodereader.com website: a humorous AI code-review site. Site changes, previews and reviews.",
         [(.repo, "https://github.com/kstrat2001/hcr"), (.folder, "~/de-projects/hcr")]),
        ("darkmux", "square.stack.3d.up",
         "darkmux, the local-LLM orchestration CLI: features, fixes, evals and releases.",
         [(.repo, "https://github.com/kstrat2001/darkmux")]),
        ("Personal brand", "megaphone",
         "Posts, threads and articles in your voice, for X and Substack.",
         []),
        ("Daily update", "calendar",
         "A short daily briefing: what ran, what finished, what needs you, what's next.",
         []),
    ]

    func allBots() -> [Bot] {
        let descriptor = FetchDescriptor<Bot>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func bot(id: UUID) -> Bot? {
        allBots().first { $0.id == id }
    }

    /// Inserts the starter bots on first launch only.
    func seedIfEmpty() {
        guard allBots().isEmpty else { return }
        let start = Date()
        for (offset, item) in Self.defaults.enumerated() {
            let bot = Bot(name: item.name, instructions: item.instructions, systemImage: item.systemImage)
            bot.createdAt = start.addingTimeInterval(Double(offset))
            context.insert(bot)
            for (index, (kind, value)) in item.resources.enumerated() {
                let resource = BotResource(kind: kind, value: value)
                resource.createdAt = bot.createdAt.addingTimeInterval(Double(index) / 10)
                context.insert(resource)
                resource.bot = bot
            }
        }
        try? context.save()
    }

    @discardableResult
    func add(name: String, instructions: String, modelName: String, systemImage: String = "sparkles") -> Bot {
        let role = Bot(
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
    func handOff(task title: String, from sender: String, to role: Bot) -> BotTask {
        let task = BotTask(title: title, why: "From \(sender)")
        context.insert(task)
        task.bot = role
        role.state = BotState.working
        append(.system, "From \(sender): \(title)", to: conversation(for: .bot(role.id)))
        return task
    }

    /// Records work a bot sends to a darkmux crew role and sets the bot
    /// Working. No fleet call yet: the run starts once the fleet is wired.
    @discardableResult
    func dispatch(task title: String, crew: CrewRole, on bot: Bot) -> BotTask {
        let task = BotTask(title: title, why: "Dispatched to \(crew.name)", crew: crew)
        context.insert(task)
        task.bot = bot
        bot.state = BotState.working
        try? context.save()
        return task
    }

    @discardableResult
    func addResource(_ kind: ResourceKind, _ value: String, to bot: Bot) -> BotResource {
        let resource = BotResource(kind: kind, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(resource)
        resource.bot = bot
        try? context.save()
        return resource
    }

    func remove(_ resource: BotResource) {
        context.delete(resource)
        try? context.save()
    }

    /// The thread for a context, created on first use. The lead bot's
    /// thread has no role id.
    func conversation(for chat: ChatContext) -> ChatConversation {
        let roleId = chat.botId
        let all = (try? context.fetch(FetchDescriptor<ChatConversation>())) ?? []
        if let existing = all.first(where: { $0.roleId == roleId }) { return existing }
        let title = roleId.flatMap { bot(id: $0)?.name } ?? LeadBot.name
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

    func setState(_ state: BotState, for role: Bot) {
        role.state = state
        try? context.save()
    }
}
