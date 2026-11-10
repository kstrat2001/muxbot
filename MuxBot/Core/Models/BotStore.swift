import Foundation
import OSLog
import SwiftData

/// Reads and writes bots, their resources and their threads in the app's
/// SwiftData store. Views read live with `@Query`; every mutation goes through here.
@MainActor
struct BotStore {
    let context: ModelContext

    /// The example bot a new user can add from the empty Home screen. Added
    /// on request only, never seeded, so a second device syncing the same
    /// iCloud data never makes a duplicate.
    nonisolated static let example = (name: "My website", systemImage: "globe",
                                      instructions: "Your website: changes, fixes and reviews. Add its project folder or GitHub repo in this bot's info.")

    private static let log = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "store")

    /// Saves, and logs a failure instead of dropping it silently.
    func save() {
        do { try context.save() } catch { Self.log.error("Saving failed: \(error.localizedDescription, privacy: .public)") }
    }

    func allBots() -> [Bot] {
        let descriptor = FetchDescriptor<Bot>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func bot(id: UUID) -> Bot? {
        (try? context.fetch(FetchDescriptor<Bot>(predicate: #Predicate { $0.id == id })))?.first
    }

    /// Adds the example bot, once.
    @discardableResult
    func addExample() -> Bot {
        if let existing = allBots().first(where: { $0.name == Self.example.name }) { return existing }
        return add(name: Self.example.name, instructions: Self.example.instructions, systemImage: Self.example.systemImage)
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
        save()
    }

    @discardableResult
    func add(name: String, instructions: String, systemImage: String = "sparkles") -> Bot {
        let role = Bot(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            systemImage: systemImage
        )
        context.insert(role)
        save()
        return role
    }

    /// Work handed to a bot: a note and a dispatch card in its thread, so
    /// it runs only after Approve there (never a bot left "Working" with
    /// nothing running).
    @discardableResult
    func handOff(task title: String, from sender: String, to role: Bot) -> BotRun {
        append(.system, "From \(sender): \(title)", to: conversation(for: .bot(role.id)))
        return proposeRun(task: title, crew: .coder, on: role)
    }

    /// Saves an action (hand-off, new bot, new resource) as an Approve card
    /// in the thread it came from. Several can wait at once.
    @discardableResult
    func proposeAction(_ action: BotAction, in chat: ChatContext) -> ChatMessage {
        let message = append(.assistant, Self.cardTitle(for: action), kind: .actionCard, to: conversation(for: chat))
        message.actionJSON = (try? JSONEncoder().encode(action)).flatMap { String(data: $0, encoding: .utf8) }
        message.actionState = .waiting
        save()
        return message
    }

    /// A waiting card's edited action, kept in the thread, so its edits
    /// survive leaving and coming back (or a relaunch).
    func updateAction(_ message: ChatMessage, to action: BotAction) {
        guard message.actionState == .waiting else { return }
        message.actionJSON = (try? JSONEncoder().encode(action)).flatMap { String(data: $0, encoding: .utf8) }
        save()
    }

    static func cardTitle(for action: BotAction) -> String {
        switch action {
        case let .handOff(_, toName, task): "Hand to \(toName): \(task)"
        case let .createBot(draft): "New bot: \(draft.name)"
        case .setUpPreview: "Set up the preview"
        case .setUpPlaybook: "Add a PLAYBOOK.md"
        case let .dispatch(crew, task): "Dispatch to \(crew.name): \(task)"
        case let .addResource(kind, value): "Add \(kind.label.lowercased()): \(value)"
        case let .tweak(_, change): "Tweak: \(change)"
        }
    }

    /// A bot proposes work for its crew: the run starts as a dispatch
    /// card in the bot's thread, waiting on Approve.
    @discardableResult
    func proposeRun(task: String, crew: CrewRole, on bot: Bot, brief: String? = nil) -> BotRun {
        let run = BotRun(task: task, crew: crew)
        run.brief = brief
        // Until darkmux reports a run's own live URL, runs share the bot's.
        context.insert(run)
        run.bot = bot
        append(.assistant, task, kind: .dispatchCard, runId: run.id, to: conversation(for: .bot(bot.id)))
        refreshState(of: bot)
        return run
    }

    func run(id: UUID) -> BotRun? {
        (try? context.fetch(FetchDescriptor<BotRun>(predicate: #Predicate { $0.id == id })))?.first
    }

    /// Moves a run through the loop and posts the next card. Returns false,
    /// changing nothing, when the event isn't allowed in the run's phase.
    @discardableResult
    func apply(_ event: RunEvent, to run: BotRun) -> Bool {
        guard let next = run.phase.next(on: event), let bot = run.bot else { return false }
        let thread = conversation(for: .bot(bot.id))
        if next == .running { run.startedAt = run.startedAt ?? .now; run.finishedAt = nil }
        // Approving or continuing a run you'd hidden: when it next needs you,
        // it shows again.
        if event == .approve || event == .tweak {
            LocalBotState.shared.update(bot.id) { entry in
                entry.dismissedRuns = entry.dismissedRuns?.filter { $0 != run.id.uuidString }
            }
        }
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
        case .cancel, .discard, .openPR, .skipPR, .close:
            save()
        }
        refreshState(of: bot)
        return true
    }

    /// Needs you while a run waits on a decision, Working while one runs,
    /// otherwise Ready.
    /// Runs an earlier build left in Keep, from before every finished run
    /// was committed: one with a commit is a committed result again (Open
    /// PR includes it); one without has nothing to open a PR from.
    func migrateKeptRuns() {
        for run in ((try? context.fetch(FetchDescriptor<BotRun>())) ?? []) where run.phase == .kept {
            run.phase = run.keptCommit == nil ? .done : .result
        }
        save()
    }

    func refreshState(of bot: Bot) {
        let phases = (bot.runs ?? []).map(\.phase)
        bot.state = (bot.runs ?? []).contains(where: \.needsYou) ? .needsYou
            : phases.contains(where: \.isActive) ? .working
            : .ready
        save()
    }

    @discardableResult
    func addResource(_ kind: ResourceKind, _ value: String, to bot: Bot) -> BotResource {
        let resource = BotResource(kind: kind, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(resource)
        resource.bot = bot
        save()
        return resource
    }

    /// Deletes a bot with its runs, resources and thread, and forgets its
    /// machine-local state. darkmux's work copy is left alone.
    func delete(_ bot: Bot) {
        let id = bot.id
        let botId: UUID? = id
        if let thread = (try? context.fetch(FetchDescriptor<ChatConversation>(predicate: #Predicate { $0.roleId == botId })))?.first {
            context.delete(thread)
        }
        context.delete(bot)
        LocalBotState.shared[id] = nil
        save()
    }

    /// Empties a thread. Runs stay (they're in Activity), and an open run
    /// (waiting for Approve, running, or a result that needs you) keeps its
    /// latest card, so it can still be decided here.
    func clearConversation(_ chat: ChatContext) {
        let messages = conversation(for: chat).messages ?? []
        var keep = Set<UUID>()
        let byRun = Dictionary(grouping: messages.filter { $0.runId != nil }, by: { $0.runId! })
        for (runId, cards) in byRun {
            guard let run = run(id: runId), run.phase.isActive || run.needsYou,
                  let latest = cards.max(by: { $0.timestamp < $1.timestamp }) else { continue }
            keep.insert(latest.id)
        }
        for message in messages where !keep.contains(message.id) { context.delete(message) }
        save()
    }

    func remove(_ resource: BotResource) {
        context.delete(resource)
        save()
    }

    /// The thread for a context, created on first use. The lead bot's
    /// thread has no role id.
    /// The thread if it exists, without making one (safe from a view's body).
    func existingConversation(for chat: ChatContext) -> ChatConversation? {
        let roleId = chat.botId
        return ((try? context.fetch(FetchDescriptor<ChatConversation>(predicate: #Predicate { $0.roleId == roleId }))) ?? []).first
    }

    func conversation(for chat: ChatContext) -> ChatConversation {
        let roleId = chat.botId
        let matching = (try? context.fetch(FetchDescriptor<ChatConversation>(predicate: #Predicate { $0.roleId == roleId }))) ?? []
        if let existing = matching.first { return existing }
        let title = roleId.flatMap { bot(id: $0)?.name } ?? LeadBot.name
        let created = ChatConversation(title: title, roleId: roleId)
        context.insert(created)
        save()
        return created
    }

    @discardableResult
    func append(_ role: ChatRole, _ text: String, kind: MessageKind = .text, runId: UUID? = nil, to conversation: ChatConversation) -> ChatMessage {
        let message = ChatMessage(role: role, content: text, kind: kind, runId: runId)
        message.conversation = conversation
        context.insert(message)
        conversation.updatedAt = .now
        save()
        return message
    }

    func setState(_ state: BotState, for role: Bot) {
        role.state = state
        save()
    }
}

/// Each bug card's own screenshot (the crop of the element it was about),
/// by message id. Kept on this device, never synced: files under
/// Application Support, in memory under tests.
@MainActor final class BugCrops {
    static let shared = BugCrops()
    private var memory: [UUID: Data] = [:]
    private let dir: URL? = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return support?.appendingPathComponent("MuxBot/bug-crops", isDirectory: true)
    }()

    subscript(id: UUID) -> Data? {
        get {
            if let data = memory[id] { return data }
            return dir.flatMap { try? Data(contentsOf: $0.appendingPathComponent("\(id.uuidString).png")) }
        }
        set {
            memory[id] = newValue
            guard let dir else { return }
            let file = dir.appendingPathComponent("\(id.uuidString).png")
            if let newValue {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? newValue.write(to: file, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

extension BotStore {
    /// Fix it now: one Coder dispatch card per bug, remembered on the bug's
    /// message (`runId`), so a second press finds it instead of another card.
    func fixBug(_ message: ChatMessage, draft: BugDraft, bot: Bot) -> (run: BotRun, isNew: Bool) {
        if let id = message.runId, let existing = run(id: id) { return (existing, false) }
        let run = proposeRun(task: "Fix: \(draft.title)", crew: .coder, on: bot, brief: "Fix this bug:\n\n" + draft.body)
        message.runId = run.id
        save()
        return (run, true)
    }
}
