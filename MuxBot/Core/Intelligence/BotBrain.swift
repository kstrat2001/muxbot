import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The lead bot on Home that orchestrates the others. Placeholder name:
/// rename it here and only here.
enum LeadBot {
    static let name = "Mux Bot"
    static let systemImage = "crown"
    static let persona = "You orchestrate the other bots, which are the user's projects and themes: hand work to the right bot, set up new bots, and answer questions about the darkmux fleet. Short, confident, friendly."
}

/// Which conversation the user is in. Follows navigation.
enum ChatContext: Hashable, Sendable {
    case lead
    case bot(UUID)

    var botId: UUID? {
        if case let .bot(id) = self { id } else { nil }
    }
}

/// A bot as the brain sees it: a plain value, safe to hand to the model.
struct BotSummary: Sendable, Equatable {
    var id: UUID
    var name: String
    var instructions: String
    var state: BotState
    /// Resource values (repo URLs, folders, links, notes). Routing reads them.
    var resources: [String] = []
}

/// A new bot proposed in conversation. Saved only when the user approves.
struct BotDraft: Sendable, Equatable {
    var name: String
    var instructions: String
    var modelName: String = ""
    var systemImage: String = "sparkles"
}

/// Something a bot wants to do. Every action waits for Approve.
enum BotAction: Sendable, Equatable {
    /// Pass work to another bot's thread.
    case handOff(toId: UUID, toName: String, task: String)
    case createBot(BotDraft)
    /// Send work to a darkmux crew role for the bot whose thread this is.
    case dispatch(crew: CrewRole, task: String)
    /// Give the bot whose thread this is a new resource.
    case addResource(kind: ResourceKind, value: String)
}

/// One bot turn: what it says, and what it proposes to do.
struct BotTurn: Sendable, Equatable {
    var reply: String
    var action: BotAction?
}

// MARK: - Keyword fallback

/// Answers without the on-device model: the lead bot routes to a bot by
/// name, theme or resources; a bot dispatches to a crew role by keyword or
/// picks up a pasted repo, folder or link; anyone can draft a new bot or
/// read the fleet briefing. Used when Foundation
/// Models is unavailable or gives an unusable answer.
enum FallbackBrain {
    private static let newBotPhrases = ["new bot", "create a bot", "add a bot", "make a bot",
                                        "new role", "create a role", "add a role", "make a role"]
    private static let fleetWords = ["machine", "fleet", "running", "free", "memory", "loaded", "runs", "mission", "busy"]
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "into", "about", "please",
        "can", "you", "our", "your", "some", "out", "all", "are", "was", "will", "what",
    ]

    /// `speaker` is the bot whose thread this is; `nil` means the lead bot.
    static func turn(for request: String, speaker: BotSummary?, bots: [BotSummary], fleet: FleetSnapshot) -> BotTurn {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let others = bots.filter { $0.id != speaker?.id }

        if newBotPhrases.contains(where: lower.contains) {
            let draft = draft(from: text)
            return BotTurn(reply: "I can set up \(draft.name). Approve to add it.", action: .createBot(draft))
        }
        if let named = others.first(where: { lower.contains($0.name.lowercased()) }) {
            return handOff(text, to: named)
        }
        if let speaker, let value = resourceValue(in: text) {
            let kind = ResourceKind.guess(for: value)
            return BotTurn(reply: "Want me to keep that as a \(kind.label.lowercased()) for \(speaker.name)?",
                           action: .addResource(kind: kind, value: value))
        }
        if tokens(lower).contains(where: { word in fleetWords.contains { word.hasPrefix($0) } }) {
            return BotTurn(reply: fleetAnswer(fleet), action: nil)
        }
        guard speaker != nil else {
            if let best = bestMatch(for: lower, in: others) { return handOff(text, to: best) }
            return BotTurn(reply: "Which bot should take this? Name one, or ask me for a new bot.", action: nil)
        }
        if let crew = crew(for: lower) {
            return BotTurn(reply: "I'll send this to the \(crew.name) crew. Approve to dispatch.",
                           action: .dispatch(crew: crew, task: text))
        }
        return BotTurn(reply: "Noted. Tell me what to build, review, evaluate or research and I'll line up the crew.", action: nil)
    }

    /// The crew role whose keywords the request mentions most.
    static func crew(for lower: String) -> CrewRole? {
        let words = tokens(lower)
        let scored = CrewRole.allCases.map { role in
            (role, words.filter { w in role.keywords.contains { w.hasPrefix($0) || $0.hasPrefix(w) } }.count)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    /// The first URL or path in the text, if any.
    static func resourceValue(in text: String) -> String? {
        text.split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)(\"'")) }
            .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") || $0.hasPrefix("~/") || ($0.hasPrefix("/") && $0.count > 1) }
    }

    static func fleetAnswer(_ fleet: FleetSnapshot) -> String {
        let active = fleet.runs.filter { $0.status == .running || $0.status == .queued }.count
        var answer = "\(active) run\(active == 1 ? "" : "s") active."
        if let roomy = fleet.roomiestMachine {
            answer += " \(roomy.name) has the most room: \(roomy.freeMemoryGB) GB free"
            answer += roomy.loadedModels.isEmpty ? "." : ", with \(roomy.loadedModels.joined(separator: ", ")) loaded."
        }
        if !fleet.isConnected { answer += " (Sample data: the fleet isn't connected yet.)" }
        return answer
    }

    private static func handOff(_ text: String, to bot: BotSummary) -> BotTurn {
        BotTurn(reply: "That's a job for \(bot.name). Approve to hand it over.",
                action: .handOff(toId: bot.id, toName: bot.name, task: text))
    }

    /// The bot whose name and instructions share the most words with the request.
    static func bestMatch(for lower: String, in bots: [BotSummary]) -> BotSummary? {
        let words = tokens(lower)
        var best: (bot: BotSummary, hits: Int)?
        for bot in bots {
            let vocabulary = tokens("\(bot.name) \(bot.instructions) \(bot.resources.joined(separator: " "))".lowercased())
            let hits = words.filter { word in vocabulary.contains { $0.hasPrefix(word) || word.hasPrefix($0) } }.count
            if hits > (best?.hits ?? 0) { best = (bot, hits) }
        }
        return best?.bot
    }

    /// Words of four letters or more, minus filler, so short words cannot
    /// prefix-match everything.
    static func tokens(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) }
    }

    /// "New bot called Release helper that tags releases" → name + instructions.
    static func draft(from text: String) -> BotDraft {
        var name = "New bot"
        var instructions = text
        for marker in [" called ", " named "] {
            guard let range = text.range(of: marker, options: .caseInsensitive) else { continue }
            let rest = text[range.upperBound...]
            let cut = rest.range(of: " that ", options: .caseInsensitive)
                ?? rest.range(of: " to ", options: .caseInsensitive)
                ?? rest.range(of: " who ", options: .caseInsensitive)
            name = String(rest[..<(cut?.lowerBound ?? rest.endIndex)])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if let cut { instructions = String(rest[cut.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
            break
        }
        return BotDraft(name: name.isEmpty ? "New bot" : name, instructions: instructions)
    }
}

// MARK: - On-device model

#if canImport(FoundationModels)
@Generable(description: "One reply from a bot in Mux Bot")
struct GeneratedTurn {
    @Guide(description: "Your reply to the user, one to three short sentences")
    var reply: String
    @Guide(description: "none to just reply; dispatch to send work to a crew role for this bot; handOff to pass work to another bot; createBot to set up a new bot; addResource to keep a repo, folder or link for this bot")
    var action: GeneratedAction
    @Guide(description: "For dispatch: which crew role does the work")
    var crew: GeneratedCrew
    @Guide(description: "For handOff: the exact name of the bot to send the work to")
    var targetBot: String
    @Guide(description: "For handOff or dispatch: the task. For createBot: one sentence on what the new bot does. For addResource: the URL or path")
    var detail: String
    @Guide(description: "For createBot: a short name for the new bot")
    var newBotName: String
}

@Generable
enum GeneratedAction {
    case none
    case dispatch
    case handOff
    case createBot
    case addResource
}

@Generable
enum GeneratedCrew {
    case coder, reviewer, evalRunner, researcher

    var role: CrewRole {
        switch self {
        case .coder: .coder
        case .reviewer: .reviewer
        case .evalRunner: .evalRunner
        case .researcher: .researcher
        }
    }
}
#endif

/// Runs a bot's side of a conversation, on device. Replies are saved to
/// the thread; any proposed action waits on an Approve / Cancel card.
@MainActor @Observable
final class BotBrain {
    struct Pending: Equatable {
        var context: ChatContext
        var action: BotAction
    }

    var isThinking = false
    var pending: Pending?
    /// Shown in the bar when the keyword fallback answered.
    var fallbackNote: String?
    var fleet = FleetSnapshot.sample
    /// Off in tests, so turns are deterministic keyword-fallback turns.
    var useOnDeviceModel = true

    var onDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        SystemLanguageModel.default.isAvailable
        #else
        false
        #endif
    }

    func send(_ request: String, in context: ChatContext, store: BotStore) async {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let bots = store.allBots().map(\.summary)
        let speaker = context.botId.flatMap { id in bots.first { $0.id == id } }
        let conversation = store.conversation(for: context)
        store.append(.user, text, to: conversation)

        isThinking = true
        defer { isThinking = false }
        pending = nil
        fallbackNote = nil

        var turn: BotTurn?
        if useOnDeviceModel && onDeviceAvailable {
            turn = await onDeviceTurn(for: text, speaker: speaker, bots: bots)
            if turn == nil { fallbackNote = "The on-device model couldn't answer, so I used simple keyword matching." }
        } else {
            fallbackNote = "Apple Intelligence isn't available here, so bots use simple keyword matching."
        }
        let result = turn ?? FallbackBrain.turn(for: text, speaker: speaker, bots: bots, fleet: fleet)
        store.append(.assistant, result.reply, to: conversation)
        switch result.action {
        case let .dispatch(crew, task)?:
            // Dispatches become a card in the thread, not a bar card.
            if let bot = context.botId.flatMap(store.bot(id:)) { store.proposeRun(task: task, crew: crew, on: bot) }
        case let action?:
            pending = Pending(context: context, action: action)
        case nil:
            break
        }
    }

    // MARK: Run loop

    /// The run a Tweak is aimed at; the next message in its bot's thread
    /// goes to that run instead of starting a new conversation turn.
    var tweakRunId: UUID?
    /// How long a simulated run takes until the fleet is connected.
    var simulatedRunSeconds: Double = 4

    /// A person's decision on a run card: Approve, Cancel, Keep, Discard,
    /// Open PR, Not now. Approve starts the (simulated) run.
    func decide(_ event: RunEvent, on run: BotRun, store: BotStore) {
        guard store.apply(event, to: run) else { return }
        if event == .approve { simulateFinish(run, store: store) }
    }

    /// Sends a follow-up to the same run (and, once wired, the same worktree).
    func tweak(_ request: String, run: BotRun, store: BotStore) {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let bot = run.bot else { return }
        store.append(.user, text, to: store.conversation(for: .bot(bot.id)))
        tweakRunId = nil
        guard store.apply(.tweak, to: run) else { return }
        simulateFinish(run, store: store)
    }

    private func simulateFinish(_ run: BotRun, store: BotStore) {
        let delay = simulatedRunSeconds
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            store.apply(.finish(summary: Self.sampleSummary(for: run)), to: run)
        }
    }

    static func sampleSummary(for run: BotRun) -> String {
        let pass = run.tweaks == 0 ? "" : " (after \(run.tweaks) tweak\(run.tweaks == 1 ? "" : "s"))"
        return "\(run.crew.name) finished “\(run.task)”\(pass). Sample result: the fleet isn't connected yet, so there is no real diff. Changed files, tests and a screenshot will show here."
    }

    func cancel() {
        pending = nil
    }

    /// Carries out the pending action and notes it in the thread it came from.
    func approve(in store: BotStore) {
        guard let pending else { return }
        let from = pending.context.botId.flatMap { store.bot(id: $0)?.name } ?? LeadBot.name
        let note: String
        switch pending.action {
        case let .handOff(toId, toName, task):
            guard let target = store.bot(id: toId) else { self.pending = nil; return }
            store.handOff(task: task, from: from, to: target)
            note = "Handed to \(toName): \(task)"
        case let .createBot(draft):
            store.add(name: draft.name, instructions: draft.instructions, modelName: draft.modelName, systemImage: draft.systemImage)
            note = "Added bot \(draft.name)."
        case let .dispatch(crew, task):
            guard let bot = pending.context.botId.flatMap(store.bot(id:)) else { self.pending = nil; return }
            store.proposeRun(task: task, crew: crew, on: bot)
            self.pending = nil
            return
        case let .addResource(kind, value):
            guard let bot = pending.context.botId.flatMap(store.bot(id:)) else { self.pending = nil; return }
            store.addResource(kind, value, to: bot)
            note = "Added \(kind.label.lowercased()): \(value)"
        }
        store.append(.system, note, to: store.conversation(for: pending.context))
        self.pending = nil
    }

    private func onDeviceTurn(for request: String, speaker: BotSummary?, bots: [BotSummary]) async -> BotTurn? {
        #if canImport(FoundationModels)
        let others = bots.filter { $0.id != speaker?.id }
        let roster = others.map { "- \($0.name): \($0.instructions)" }.joined(separator: "\n")
        let crewList = CrewRole.allCases.map(\.name).joined(separator: ", ")
        let identity = speaker.map {
            "You are \($0.name), a bot in Mux Bot. \($0.instructions)\nYour resources: \($0.resources.isEmpty ? "none yet" : $0.resources.joined(separator: ", "))\nYour darkmux crew: \(crewList). Dispatch work to the crew role that fits."
        } ?? "You are \(LeadBot.name), the lead bot in Mux Bot. \(LeadBot.persona) Route work to the bot whose theme or resources fit; you don't dispatch yourself."
        let session = LanguageModelSession(instructions: """
            \(identity)
            Hand work to another bot only when the user asks or it clearly belongs to that bot. \
            When asked where work should run, suggest the online machine with the most free memory.
            Other bots:
            \(roster.isEmpty ? "(none yet)" : roster)
            \(fleet.briefing)
            """)
        do {
            let g = try await session.respond(to: request, generating: GeneratedTurn.self).content
            switch g.action {
            case .none:
                return BotTurn(reply: g.reply, action: nil)
            case .handOff:
                let wanted = g.targetBot.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let target = others.first(where: { $0.name.lowercased() == wanted }) else {
                    return BotTurn(reply: g.reply, action: nil)
                }
                return BotTurn(reply: g.reply, action: .handOff(toId: target.id, toName: target.name,
                                                                task: g.detail.isEmpty ? request : g.detail))
            case .createBot:
                guard !g.newBotName.isEmpty else { return BotTurn(reply: g.reply, action: nil) }
                return BotTurn(reply: g.reply, action: .createBot(BotDraft(name: g.newBotName, instructions: g.detail)))
            case .dispatch:
                guard speaker != nil else { return BotTurn(reply: g.reply, action: nil) }
                return BotTurn(reply: g.reply, action: .dispatch(crew: g.crew.role, task: g.detail.isEmpty ? request : g.detail))
            case .addResource:
                let value = g.detail.trimmingCharacters(in: .whitespacesAndNewlines)
                guard speaker != nil, !value.isEmpty else { return BotTurn(reply: g.reply, action: nil) }
                return BotTurn(reply: g.reply, action: .addResource(kind: ResourceKind.guess(for: value), value: value))
            }
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

extension Bot {
    var summary: BotSummary {
        BotSummary(id: id, name: name, instructions: instructions, state: state,
                   resources: sortedResources.map(\.value))
    }
}
