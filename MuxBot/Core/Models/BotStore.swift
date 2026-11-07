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
         [(.repo, "https://github.com/kstrat2001/hcr")]),
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

    /// Earlier builds kept a darkmux work folder as a folder resource
    /// (`~/.darkmux/worktrees/<name>`): it becomes the bot's workspace name
    /// on this machine, and the folder resource goes.
    func migrateWorkCopies(machine: String) {
        for bot in allBots() {
            for resource in bot.sortedResources where resource.kind == .folder {
                guard let range = resource.value.range(of: "/.darkmux/worktrees/") else { continue }
                let name = resource.value[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
                if bot.workspaceName == nil, !name.isEmpty {
                    bot.workspaceName = name
                    bot.workspaceMachine = machine
                }
                remove(resource)
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

    /// Saves an action (hand-off, new bot, new resource) as an Approve card
    /// in the thread it came from. Several can wait at once.
    @discardableResult
    func proposeAction(_ action: BotAction, in chat: ChatContext) -> ChatMessage {
        let message = append(.assistant, Self.cardTitle(for: action), kind: .actionCard, to: conversation(for: chat))
        message.actionJSON = (try? JSONEncoder().encode(action)).flatMap { String(data: $0, encoding: .utf8) }
        message.actionState = .waiting
        try? context.save()
        return message
    }

    static func cardTitle(for action: BotAction) -> String {
        switch action {
        case let .handOff(_, toName, task): "Hand to \(toName): \(task)"
        case let .createBot(draft): "New bot: \(draft.name)"
        case let .dispatch(crew, task): "Dispatch to \(crew.name): \(task)"
        case let .addResource(kind, value): "Add \(kind.label.lowercased()): \(value)"
        }
    }

    /// A bot proposes work for its crew: the run starts as a dispatch
    /// card in the bot's thread, waiting on Approve.
    @discardableResult
    func proposeRun(task: String, crew: CrewRole, on bot: Bot, brief: String? = nil) -> BotRun {
        let run = BotRun(task: task, crew: crew)
        run.brief = brief
        // Until darkmux reports a run's own live URL, runs share the bot's.
        run.previewURL = bot.sortedResources.last { $0.kind == .previewURL }?.value
        context.insert(run)
        run.bot = bot
        append(.assistant, task, kind: .dispatchCard, runId: run.id, to: conversation(for: .bot(bot.id)))
        refreshState(of: bot)
        return run
    }

    func run(id: UUID) -> BotRun? {
        let all = (try? context.fetch(FetchDescriptor<BotRun>())) ?? []
        return all.first { $0.id == id }
    }

    /// Moves a run through the loop and posts the next card. Returns false,
    /// changing nothing, when the event isn't allowed in the run's phase.
    @discardableResult
    func apply(_ event: RunEvent, to run: BotRun) -> Bool {
        guard let next = run.phase.next(on: event), let bot = run.bot else { return false }
        let thread = conversation(for: .bot(bot.id))
        if next == .running { run.startedAt = run.startedAt ?? .now; run.finishedAt = nil }
        if run.phase == .running && next != .running { run.finishedAt = .now }
        run.phase = next
        switch event {
        case .approve:
            append(.system, "Dispatched to \(run.crew.name).", kind: .runCard, runId: run.id, to: thread)
        case let .finish(summary):
            run.summary = summary
            append(.assistant, summary, kind: .resultCard, runId: run.id, to: thread)
        case .tweak:
            run.tweaks += 1
            append(.system, "Tweak \(run.tweaks) sent to \(run.crew.name).", kind: .runCard, runId: run.id, to: thread)
        case .keep:
            let kept = run.keptBranch.map { b in "Committed to \(b)\(run.keptCommit.map { " (\($0))" } ?? "")." } ?? "Kept."
            append(.assistant, "\(kept) Open a pull request for it?", kind: .prCard, runId: run.id, to: thread)
        case .stop:
            append(.system, "Stopped.", to: thread)
        case let .fail(reason, details):
            run.details = details
            run.summary = reason
            append(.assistant, reason, kind: .resultCard, runId: run.id, to: thread)
        case .cancel, .discard, .openPR, .skipPR:
            try? context.save()
        }
        refreshState(of: bot)
        return true
    }

    /// Needs you while a run waits on a decision, Working while one runs,
    /// otherwise Ready.
    func refreshState(of bot: Bot) {
        let phases = (bot.runs ?? []).map(\.phase)
        bot.state = phases.contains(where: \.awaitsYou) ? .needsYou
            : phases.contains(where: \.isActive) ? .working
            : (bot.tasks ?? []).isEmpty ? .ready : bot.state
        try? context.save()
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

    @discardableResult
    func append(_ role: ChatRole, _ text: String, kind: MessageKind = .text, runId: UUID? = nil, to conversation: ChatConversation) -> ChatMessage {
        let message = ChatMessage(role: role, content: text, kind: kind, runId: runId)
        message.conversation = conversation
        context.insert(message)
        conversation.updatedAt = .now
        try? context.save()
        return message
    }

    func setState(_ state: BotState, for role: Bot) {
        role.state = state
        try? context.save()
    }
}
