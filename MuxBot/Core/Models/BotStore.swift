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
                                      instructions: "Your website: changes, fixes and reviews. Add a repo, folder or preview link below.")

    private static let log = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "store")

    /// Saves, and logs a failure instead of dropping it silently.
    func save() {
        do { try context.save() } catch { Self.log.error("Saving failed: \(error.localizedDescription, privacy: .public)") }
    }

    func allBots() -> [Bot] {
        let descriptor = FetchDescriptor<Bot>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The bots in the lists: every bot but the archived ones.
    func activeBots() -> [Bot] { allBots().filter { !$0.isArchived } }

    /// Archived bots, most recently archived first.
    func archivedBots() -> [Bot] {
        allBots().filter(\.isArchived).sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    /// Why a bot can't be archived now: a run going (here or on another
    /// Mac). Nil when it can. Something waiting on you doesn't block: an
    /// archived bot's runs leave Needs you (`NeedsYou.isWaiting`) and come
    /// back with Restore, so an old card nobody can see never holds it.
    static func archiveBlocker(_ bot: Bot) -> String? {
        if (bot.runs ?? []).contains(where: { $0.phase.isActive }) {
            return String(localized: "\(bot.name) has a run going. Stop it or let it finish, then archive.")
        }
        return nil
    }

    /// Moves a bot out of the lists. Its thread, runs, links and work copy
    /// stay as they are, so Restore brings it back exactly.
    func archive(_ bot: Bot) {
        bot.archivedAt = Date()
        save()
    }

    /// Back in the lists from Archived or Hidden.
    func restore(_ bot: Bot) {
        bot.archivedAt = nil
        bot.hiddenAt = nil
        save()
    }

    /// Out of the sidebar and Home only: runs, previews and hand-offs go on
    /// as before, and it shows again while something waits on you.
    func hide(_ bot: Bot) {
        bot.hiddenAt = Date()
        save()
    }

    /// Hidden bots, most recently hidden first.
    func hiddenBots() -> [Bot] {
        allBots().filter(\.isHidden).sorted { ($0.hiddenAt ?? .distantPast) > ($1.hiddenAt ?? .distantPast) }
    }

    /// Whether a bot has a row in the sidebar and a tile on Home: not
    /// archived, and not hidden unless something waits on you there.
    static func isListed(_ bot: Bot) -> Bool {
        !bot.isArchived && (!bot.isHidden || NeedsYou.shownState(bot) == .needsYou)
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
    func handOff(task title: String, from sender: String, to role: Bot, brief: String? = nil) -> BotRun {
        append(.system, "From \(sender): \(title)", to: conversation(for: .bot(role.id)))
        return proposeRun(task: title, crew: .coder, on: role, brief: brief)
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

    /// A hand edit darkmux has made (#3533): a run with no dispatch card,
    /// already running, so `apply(.finish)` posts its result with Undo.
    func recordHandEdit(task: String, on bot: Bot) -> BotRun {
        let run = BotRun(task: task, crew: .coder)
        context.insert(run)
        run.bot = bot
        run.phase = .running
        run.startedAt = .now
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
        for thread in (try? context.fetch(FetchDescriptor<ChatConversation>(predicate: #Predicate { $0.roleId == botId }))) ?? [] {
            // Its bug cards' screenshots on this device go with it.
            for message in thread.messages ?? [] where message.kind == .bugCard { BugCrops.shared[message.id] = nil }
            context.delete(thread)
        }
        context.delete(bot)
        LocalBotState.shared[id] = nil
        // And its own model choices, on every machine.
        ModelSettingsStore.shared.removeBotModes(bot: id)
        save()
    }

    /// Empties a thread. Runs stay (they're in Activity), and an open run
    /// (waiting for Approve, running, or a result that needs you) keeps its
    /// latest card, so it can still be decided here.
    @discardableResult
    func clearConversation(_ chat: ChatContext) -> ClearedConversation {
        let messages = conversation(for: chat).messages ?? []
        // Runs already in a PR stay shipped once its card is gone.
        if let botId = chat.botId, let lastPR = messages.filter({ $0.kind == .prCard }).map(\.timestamp).max() {
            LocalBotState.shared.update(botId) { $0.shippedThrough = max($0.shippedThrough ?? .distantPast, lastPR) }
        }
        var keep = Set<UUID>()
        let byRun = Dictionary(grouping: messages.filter { $0.runId != nil }, by: { $0.runId! })
        for (runId, cards) in byRun {
            guard let run = run(id: runId), run.phase.isActive || run.needsYou,
                  let latest = cards.max(by: { $0.timestamp < $1.timestamp }) else { continue }
            keep.insert(latest.id)
        }
        let cleared = messages.filter { !keep.contains($0.id) }
        let snapshot = ClearedConversation(context: chat, messages: cleared.map(ClearedConversation.Message.init))
        for message in cleared { context.delete(message) }
        save()
        return snapshot
    }

    /// Undo for Clear Conversation: the messages come back as they were
    /// (same ids, times and cards). Ones already back are skipped.
    func undoClear(_ cleared: ClearedConversation) {
        let thread = conversation(for: cleared.context)
        let present = Set((thread.messages ?? []).map(\.id))
        for kept in cleared.messages where !present.contains(kept.id) {
            let message = ChatMessage(role: kept.role, content: kept.content, kind: kept.kind, runId: kept.runId)
            message.id = kept.id
            message.timestamp = kept.timestamp
            message.intentRaw = kept.intentRaw
            message.elementJSON = kept.elementJSON
            message.actionJSON = kept.actionJSON
            message.actionStateRaw = kept.actionStateRaw
            context.insert(message)
            message.conversation = thread
        }
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
        threads(for: chat).first
    }

    /// Every thread for a context, oldest first: a second one is another
    /// device's copy that synced in.
    private func threads(for chat: ChatContext) -> [ChatConversation] {
        let roleId = chat.botId
        let descriptor = FetchDescriptor<ChatConversation>(predicate: #Predicate { $0.roleId == roleId },
                                                           sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The thread for a context, created on first use. Copies made on
    /// another device merge into the oldest: their messages move to it.
    func conversation(for chat: ChatContext) -> ChatConversation {
        let roleId = chat.botId
        let matching = threads(for: chat)
        if let oldest = matching.first {
            if matching.count > 1 { merge(matching.dropFirst(), into: oldest) }
            return oldest
        }
        let title = roleId.flatMap { bot(id: $0)?.name } ?? LeadBot.name
        let created = ChatConversation(title: title, roleId: roleId)
        created.id = ChatConversation.threadId(for: chat)
        context.insert(created)
        save()
        return created
    }

    /// Every thread with more than one copy, merged. Runs at launch; a copy
    /// that syncs in later is merged by `conversation(for:)` when used.
    func mergeDuplicateThreads() {
        let all = (try? context.fetch(FetchDescriptor<ChatConversation>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]))) ?? []
        for (_, copies) in Dictionary(grouping: all, by: \.roleId) where copies.count > 1 {
            merge(copies.dropFirst(), into: copies[0])
        }
    }

    private func merge(_ copies: ArraySlice<ChatConversation>, into oldest: ChatConversation) {
        for copy in copies {
            for message in copy.messages ?? [] { message.conversation = oldest }
            if let read = copy.lastReadAt, read > (oldest.lastReadAt ?? .distantPast) { oldest.lastReadAt = read }
            oldest.updatedAt = max(oldest.updatedAt, copy.updatedAt)
            copy.messages = []
            context.delete(copy)
        }
        save()
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
        if TestIsolation.isTesting { return nil }
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
    /// The run a bug card sent to Coder, unless you canceled it (or it
    /// failed before darkmux had it): then the card offers Fix it now again.
    func sentRun(for message: ChatMessage) -> BotRun? {
        guard let id = message.runId, let run = run(id: id) else { return nil }
        if run.phase == .canceled || (run.phase == .failed && run.darkmuxWorkId == nil) { return nil }
        return run
    }

    func fixBug(_ message: ChatMessage, draft: BugDraft, bot: Bot) -> (run: BotRun, isNew: Bool) {
        if let existing = sentRun(for: message) { return (existing, false) }
        let run = proposeRun(task: "Fix: \(draft.title)", crew: .coder, on: bot, brief: "Fix this bug:\n\n" + draft.body)
        message.runId = run.id
        save()
        return (run, true)
    }
}

/// What Clear Conversation took away, kept in memory on this device so it
/// can be undone until the app quits.
struct ClearedConversation: Equatable {
    struct Message: Equatable {
        var id: UUID
        var role: ChatRole
        var content: String
        var timestamp: Date
        var kind: MessageKind
        var runId: UUID?
        var intentRaw: String?
        var elementJSON: String?
        var actionJSON: String?
        var actionStateRaw: String?

        init(_ message: ChatMessage) {
            id = message.id
            role = message.role
            content = message.content
            timestamp = message.timestamp
            kind = message.kind
            runId = message.runId
            intentRaw = message.intentRaw
            elementJSON = message.elementJSON
            actionJSON = message.actionJSON
            actionStateRaw = message.actionStateRaw
        }
    }

    let context: ChatContext
    let messages: [Message]
}
