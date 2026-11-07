import Foundation
import SwiftData

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The lead bot on Home that orchestrates the others. Placeholder name:
/// rename it here and only here.
enum LeadBot {
    static let name = "Mux Bot"
    static let systemImage = "crown"
    static let persona = "You orchestrate the other bots, which are the user's projects and themes: hand work to the right bot, and set up new bots. Short, confident, friendly."
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
struct BotDraft: Sendable, Equatable, Codable {
    var name: String
    var instructions: String
    var systemImage: String = "sparkles"
}

/// Something a bot wants to do. Every action waits for Approve.
enum BotAction: Sendable, Equatable, Codable {
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
/// picks up a pasted repo, folder or link; anyone can draft a new bot.
/// Fleet questions get an honest "can't see it yet". Used when Foundation
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
    static func turn(for request: String, speaker: BotSummary?, bots: [BotSummary]) -> BotTurn {
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
        if speaker != nil, isVisualReport(lower) {
            return visualReportTurn(text)
        }
        if let speaker, let value = resourceValue(in: text) {
            let kind = ResourceKind.guess(for: value)
            return BotTurn(reply: "Want me to keep that as a \(kind.label.lowercased()) for \(speaker.name)?",
                           action: .addResource(kind: kind, value: value))
        }
        if tokens(lower).contains(where: { word in fleetWords.contains { word.hasPrefix($0) } }) {
            return BotTurn(reply: fleetAnswer, action: nil)
        }
        guard speaker != nil else {
            if let best = bestMatch(for: lower, in: others) { return handOff(text, to: best) }
            return BotTurn(reply: "Which bot should take this? Name one, or ask me for a new bot.", action: nil)
        }
        if let crew = crew(for: lower) {
            return BotTurn(reply: "I'll send this to the \(crew.name) crew. Approve to dispatch.",
                           action: .dispatch(crew: crew, task: text))
        }
        if text.hasSuffix("?") {
            return BotTurn(reply: "I can't answer that without the on-device model. I can list open issues or send work to the crew.", action: nil)
        }
        return BotTurn(reply: "Without the on-device model I can only act on clear requests: tell me what to build, review, test or research, or ask about open issues.", action: nil)
    }

    /// "The border has no padding", "the cards overlap the footer": the
    /// user describing something they see in the preview.
    static func isVisualReport(_ lower: String) -> Bool {
        let words = ["looks", "border", "padding", "margin", "overlap", "misaligned", "aligned", "cut off",
                     "too big", "too small", "spacing", "font", "color", "colour", "wraps", "cramped", "broken", "off-center", "contrast"]
        return words.contains { lower.contains($0) } && !lower.hasSuffix("?")
    }

    /// The bot can't see the preview: it takes the user's word and offers
    /// a Coder fix instead of judging the page.
    static func visualReportTurn(_ text: String) -> BotTurn {
        BotTurn(reply: "I can't see the preview, so I'll go by your description. Want the Coder crew to fix it?",
                action: .dispatch(crew: .coder, task: "Fix: \(text)"))
    }

    /// "Any bug tickets?", "open issues", "what PRs are open" and the like.
    static func isIssueQuestion(_ lower: String) -> Bool {
        ["issue", "ticket", "bug", "pull request", "prs"].contains { lower.contains($0) }
            && !["fix the", "fix this", "build", "implement"].contains { lower.contains($0) }
    }

    /// Lists matching issues and offers the first as a Coder dispatch.
    static func issuesTurn(_ issues: [GitHubIssue], repo: String, asked lower: String) -> BotTurn {
        let label = lower.contains("bug") ? "bug" : nil
        let includePRs = lower.contains("pull request") || lower.contains("prs")
        let matches = IssueQuery.filter(issues, label: label, includePullRequests: includePRs)
        guard !matches.isEmpty else {
            return BotTurn(reply: "No open \(label.map { "\($0) " } ?? "")issues on \(repo).", action: nil)
        }
        let fixed = IssueQuery.fixedBy(issues)
        let list = IssueQuery.lines(Array(matches.prefix(5)), all: issues).map { "• \($0)" }.joined(separator: "\n")
        let more = matches.count > 5 ? "\n…and \(matches.count - 5) more." : ""
        // Offer the first issue nobody has a PR for yet.
        guard let first = matches.first(where: { !$0.isPullRequest && fixed[$0.number] == nil }) else {
            let covered = matches.compactMap { i in fixed[i.number].map { "PR #\($0[0]) is open for #\(i.number)" } }
            let tail = covered.isEmpty ? "" : "\n\(covered.joined(separator: "; ")): review it on GitHub."
            return BotTurn(reply: "Open on \(repo):\n\(list)\(more)\(tail)", action: nil)
        }
        return BotTurn(reply: "Open on \(repo):\n\(list)\(more)\nFix #\(first.number) with Coder?",
                       action: .dispatch(crew: .coder, task: "Fix #\(first.number): \(first.title) (\(repo))"))
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

    /// darkmux doesn't report its machines to apps yet: say so.
    static let fleetAnswer = "I can't see the fleet yet: darkmux doesn't share its machines with this app. Runs this app starts show in Activity."

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
    var isThinking = false
    /// Shown in the bar when the keyword fallback answered.
    var fallbackNote: String?
    /// Off in tests, so turns are deterministic keyword-fallback turns.
    var useOnDeviceModel = true
    var github: any GitHubClient = RESTGitHubClient()
    /// The pairing with darkmux on this Mac; when paired, approved runs go
    /// to darkmux.
    weak var connection: FleetConnection?
    /// Reads facts and snapshots from the live preview, when one is open.
    weak var pageInspector: (any PageInspecting)?
    /// Threads already told that the on-device model isn't working here.
    private var toldFallback: Set<ChatContext> = []

    /// The on-device model has a ~4K-token context, shared by these
    /// instructions, the tool schema, the request and the answer. Each turn
    /// is a fresh session (no history), so only this has to stay small:
    /// short roster lines, a "can't see the fleet" line only when asked, and a
    /// compact form (identity and rules only) for the retry after an
    /// overflow.
    nonisolated static func instructions(for request: String, speaker: BotSummary?, bots: [BotSummary],
                                         compact: Bool) -> String {
        let lower = request.lowercased()
        let crewList = CrewRole.allCases.map(\.name).joined(separator: ", ")
        let identity = speaker.map {
            "You are \($0.name), a bot in Mux Bot. \($0.instructions.prefix(160))\nYour darkmux crew: \(crewList). Dispatch work to the crew role that fits."
        } ?? "You are \(LeadBot.name), the lead bot in Mux Bot. \(LeadBot.persona) Route work to the bot whose theme or resources fit; you don't dispatch yourself."
        let rules = """
            Answer in plain words; propose an action only when the user wants something done. \
            You cannot see the website. Never say how something looks. \
            Never mention tools. Never claim whether issues exist without checking. \
            If an issue already has an open PR, say so with its number (PR #9) instead of offering to fix it. Write issue and PR numbers as #N. \
            \(speaker == nil ? "To fix an issue, hand it off to the bot that owns that repo." : "To fix an issue, dispatch it to the Coder crew.")
            """
        guard !compact else { return identity + "\n" + rules }
        let others = bots.filter { $0.id != speaker?.id }.prefix(12)
        let roster = others.map { "- \($0.name): \($0.instructions.prefix(70))" }.joined(separator: "\n")
        let wantsFleet = ["machine", "fleet", "memory", "loaded", "running", "free", "where should"].contains { lower.contains($0) }
        return [identity, rules,
                "Hand work to another bot only when the user asks or it clearly belongs to that bot.",
                "Other bots:\n" + (roster.isEmpty ? "(none yet)" : roster),
                wantsFleet ? "You can't see the darkmux fleet yet (its machines, models or load). If asked, say so plainly; never guess." : ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Errors about one turn (too long, refused, malformed), not about the
    /// model being unavailable.
    nonisolated static func isPerTurnFailure(_ error: any Error) -> Bool {
        #if canImport(FoundationModels)
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize, .guardrailViolation, .decodingFailure, .refusal, .unsupportedLanguageOrLocale: return true
            default: return false
            }
        }
        #endif
        return false
    }

    nonisolated static func describe(_ error: any Error) -> String {
        #if canImport(FoundationModels)
        if let e = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = e {
            return "That was too long for the on-device model."
        }
        #endif
        return "The on-device model couldn't answer that."
    }

    /// Why the on-device model can't be used, or nil when it reports ready.
    /// (The simulator can report ready and still fail at inference when the
    /// Mac has Apple Intelligence off; that failure is caught per turn.)
    var onDeviceUnavailableReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is turned off"
        case .unavailable(.deviceNotEligible): "this device doesn't support Apple Intelligence"
        case .unavailable(.modelNotReady): "the model is still downloading"
        case .unavailable: "the model is unavailable"
        }
        #else
        "Foundation Models isn't available"
        #endif
    }

    /// A bot answers for its own repo. The lead bot answers for the bot the
    /// request names (or best matches) and offers a handoff, not a dispatch.
    private func issuesTurn(for text: String, repos: [BotRepo], lead: Bool, bots: [BotSummary]) async -> BotTurn {
        let lower = text.lowercased()
        var target = repos.first
        if lead {
            let withRepo = bots.filter { b in repos.contains { $0.bot == b.name } }
            let pick = withRepo.first { lower.contains($0.name.lowercased()) } ?? FallbackBrain.bestMatch(for: lower, in: withRepo)
            target = pick.flatMap { b in repos.first { $0.bot == b.name } }
            guard target != nil else {
                let names = withRepo.map(\.name).joined(separator: ", ")
                return BotTurn(reply: names.isEmpty ? "None of your bots has a GitHub repo yet." : "Which bot's repo should I check? \(names).", action: nil)
            }
        }
        guard let ref = target else {
            return BotTurn(reply: "I don't have a GitHub repo yet. Paste its URL and I'll keep it.", action: nil)
        }
        do {
            var turn = FallbackBrain.issuesTurn(try await github.openIssues(repo: ref.repo), repo: ref.repo, asked: lower)
            if lead, case let .dispatch(_, task)? = turn.action, let bot = bots.first(where: { $0.name == ref.bot }) {
                turn.reply = turn.reply.replacingOccurrences(of: "with Coder?", with: "with \(bot.name)? I'll hand it over.")
                turn.action = .handOff(toId: bot.id, toName: bot.name, task: task)
            }
            return turn
        } catch {
            return BotTurn(reply: "I couldn't read issues on \(ref.repo): \(error.localizedDescription)", action: nil)
        }
    }

    /// Sends a message. `element` is what you picked in the preview;
    /// `forced` is an intent you chose (a prefix like "bug:" does the same).
    func send(_ request: String, in context: ChatContext, store: BotStore,
              element: PickedElement? = nil, forced: Intent? = nil) async {
        // "no, it's a question": re-read the previous message instead.
        if let corrected = Intent.correction(in: request),
           let previous = (store.conversation(for: context).messages ?? [])
               .filter({ $0.role == .user && $0.kind == .text })
               .max(by: { $0.timestamp < $1.timestamp }) {
            let thread = store.conversation(for: context)
            store.append(.user, request.trimmingCharacters(in: .whitespacesAndNewlines), to: thread)
            // Drop a card the misread proposed, if it's still waiting.
            for run in (context.botId.flatMap(store.bot(id:))?.runs ?? []) where run.phase == .proposed && run.createdAt >= previous.timestamp {
                store.apply(.cancel, to: run)
            }
            await reinterpret(previous, as: corrected, store: store)
            return
        }
        let (prefix, body) = Intent.parse(request)
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || element != nil else { return }
        let conversation = store.conversation(for: context)
        let shown = [text, element.map { "📍 \($0.chip)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let message = store.append(.user, shown, to: conversation)
        message.elementJSON = element.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        await respond(to: message, text: text, context: context, store: store, element: element, explicit: forced ?? prefix)
    }

    /// Answers the same message again under the intent you picked from its chip.
    func reinterpret(_ message: ChatMessage, as intent: Intent, store: BotStore) async {
        guard let conversation = message.conversation else { return }
        let context: ChatContext = conversation.roleId.map { .bot($0) } ?? .lead
        let element = message.elementJSON.flatMap { try? JSONDecoder().decode(PickedElement.self, from: Data($0.utf8)) }
        let text = message.content.split(separator: "\n").filter { !$0.hasPrefix("📍") }.joined(separator: "\n")
        await respond(to: message, text: text, context: context, store: store, element: element, explicit: intent)
    }

    private func respond(to message: ChatMessage, text: String, context: ChatContext, store: BotStore,
                         element: PickedElement?, explicit: Intent?) async {
        let bots = store.allBots().map(\.summary)
        let speaker = context.botId.flatMap { id in bots.first { $0.id == id } }
        let conversation = store.conversation(for: context)
        // "what's this?" about a picked element: explain it from its facts.
        if let element, explicit == nil || explicit == .ask, ElementExplainer.isWhatsThis(text) {
            message.intentRaw = Intent.ask.rawValue
            let pageFile = context.botId.flatMap(store.bot(id:)).flatMap(recipe(for:))?.pageFile
            store.append(.assistant, ElementExplainer.explain(element, pageFile: pageFile), to: conversation)
            return
        }
        let intent = explicit ?? Intent.infer(text, hasElement: element != nil)
        message.intentRaw = intent?.rawValue
        try? store.context.save()

        isThinking = true
        defer { isThinking = false }
        fallbackNote = nil

        // A bot reads its own repos; the lead bot reads every bot's.
        let repos = (speaker.map { [$0] } ?? bots).flatMap { bot in
            bot.resources.compactMap(GitHubIssue.repoSlug(from:)).map { BotRepo(bot: bot.name, repo: $0) }
        }
        let bot = context.botId.flatMap(store.bot(id:))
        let target = element.map { " (`\($0.selector)` on \($0.url))" } ?? ""
        if speaker == nil, let intent, [.bug, .fix, .review].contains(intent) {
            store.append(.assistant, "Open the bot for that project to report bugs or send work to its crew.", to: conversation)
            return
        }
        switch intent {
        case .bug?:
            // Never let a model that can't see the page judge it: measure it
            // and draft an issue.
            await draftBug(text, element: element, repo: repos.first?.repo, store: store, conversation: conversation)
            return
        case .fix?, .review?:
            let crew: CrewRole = intent == .fix ? .coder : .reviewer
            var task = text + target
            var brief: String?
            // "fix #8" or an issue link: dispatch that issue, with its body as the brief.
            if let number = Intent.issueNumber(in: text), let repo = repos.first?.repo {
                let issue = (try? await github.openIssues(repo: repo))?.first { $0.number == number }
                guard let issue else {
                    store.append(.assistant, "I can't find an open issue #\(number) on \(repo).", to: conversation)
                    return
                }
                guard let issueBrief = IssueBrief.compose(issue: issue, repo: repo, crew: crew,
                                                          pageFile: bot.flatMap(recipe(for:))?.pageFile) else {
                    // Never send a model to search blind on a title.
                    store.append(.assistant, "#\(number) doesn't say where. Which page and element? Point at it in the preview (Pick), then say what's wrong.", to: conversation)
                    return
                }
                task = "\(crew == .coder ? "Fix" : "Review") #\(number): \(issue.title) (\(repo))"
                brief = issueBrief
            }
            store.append(.assistant, "I'll send this to the \(crew.name) crew. Approve to dispatch.", to: conversation)
            if let bot { store.proposeRun(task: task, crew: crew, on: bot, brief: brief) }
            return
        case .issues?:
            let turn = await issuesTurn(for: text, repos: repos, lead: speaker == nil, bots: bots)
            apply(turn, context: context, store: store, conversation: conversation)
            return
        case .ask?, nil:
            break
        }

        // Questions and everything else: the on-device model, then keywords.
        let prompt = element.map { "\(text)\n\nAbout this element on the page: \(BugReport.describe($0.asFacts).joined()) Selector: \($0.selector)." } ?? text
        var turn: BotTurn?
        var turnNote: String?
        var unavailableReason = onDeviceUnavailableReason
        if useOnDeviceModel && unavailableReason == nil {
            do {
                do {
                    turn = try await onDeviceTurn(for: prompt, speaker: speaker, bots: bots, repos: repos)
                } catch let error as LanguageModelSession.GenerationError {
                    // Too long: retry once with a fresh, trimmed session.
                    guard case .exceededContextWindowSize = error else { throw error }
                    turn = try await onDeviceTurn(for: String(prompt.prefix(1200)), speaker: speaker, bots: bots,
                                                  repos: repos, compact: true)
                }
            } catch {
                // Only "can't run at all" errors mean the model is unavailable;
                // a too-long or refused turn just falls back for this message.
                if Self.isPerTurnFailure(error) { turnNote = Self.describe(error) } else { unavailableReason = error.localizedDescription }
            }
        }
        if turn == nil, let reason = unavailableReason, useOnDeviceModel, !toldFallback.contains(context) {
            toldFallback.insert(context)
            store.append(.system, "The on-device model isn't working here (\(reason)). I'm using simple keyword matching: I can list issues and send work to the crew, but I can't hold a real conversation.", to: conversation)
        }
        fallbackNote = !useOnDeviceModel || turn != nil ? nil
            : unavailableReason != nil ? "Keyword matching: the on-device model isn't available."
            : turnNote.map { "\($0) I used keyword matching for this message." }
            ?? "The on-device model's answer wasn't usable, so I used keyword matching."
        var result = turn ?? FallbackBrain.turn(for: text, speaker: speaker, bots: bots)
        if intent == .ask { result.action = nil }   // a question never proposes work
        apply(result, context: context, store: store, conversation: conversation)
    }

    private func apply(_ result: BotTurn, context: ChatContext, store: BotStore, conversation: ChatConversation) {
        store.append(.assistant, result.reply, to: conversation)
        switch result.action {
        case let .dispatch(crew, task)?:
            // Dispatches become a card in the thread, not a bar card.
            if let bot = context.botId.flatMap(store.bot(id:)) { store.proposeRun(task: task, crew: crew, on: bot) }
        case let action?:
            store.proposeAction(action, in: context)
        case nil:
            break
        }
    }

    // MARK: Bug reports

    private func draftBug(_ text: String, element: PickedElement?, repo: String?, store: BotStore, conversation: ChatConversation) async {
        let facts: PageFacts?
        if let element { facts = element.asFacts } else { facts = await pageInspector?.facts(for: BugReport.searchTerms(in: text)) }
        let measured = facts.map(BugReport.describe) ?? []
        let reply: String
        if facts == nil {
            reply = "I can't see the site and the preview isn't open, so I couldn't measure anything. I drafted a bug from your description."
        } else if measured.isEmpty {
            reply = "I couldn't find that element on the page to measure it. I drafted a bug from your description."
        } else {
            reply = measured.joined(separator: " ") + " I drafted a bug."
        }
        store.append(.assistant, reply, to: conversation)
        var draft = BugReport.draft(from: text.isEmpty ? "Problem with \(element?.label ?? "this element")" : text,
                                    facts: facts, page: nil, repo: repo)
        draft.selector = element?.selector
        draft.expected = await expectedLine(for: text)
        if let json = try? JSONEncoder().encode(draft), let body = String(data: json, encoding: .utf8) {
            store.append(.assistant, body, kind: .bugCard, to: conversation)
        }
    }

    /// One sentence on the expected behavior, written by the on-device model
    /// from the user's words; nil when the model isn't available.
    private func expectedLine(for report: String) async -> String? {
        #if canImport(FoundationModels)
        guard useOnDeviceModel, onDeviceUnavailableReason == nil, !report.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: "You turn a bug description into one short sentence saying what should happen instead. Reply with only that sentence.")
        let line = try? await session.respond(to: report).content.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
        #else
        return nil
        #endif
    }

    // MARK: Preview recipes

    enum RecipeState: Equatable {
        case loading, ready(PreviewManifest, fromLocalCopy: Bool), missing, failed(String)
    }

    /// `.darkmux/preview.json` per repo: from the bot's workspace when
    /// darkmux lets this app read it, else read-only from GitHub.
    var recipes: [String: RecipeState] = [:]

    func loadRecipe(for repo: String, workspace: String? = nil) async {
        if case .ready? = recipes[repo] { return }
        recipes[repo] = .loading
        if let workspace, let connection, let token = connection.token,
           let local = try? await connection.client.recipe(token: token, workspace: workspace) {
            recipes[repo] = .ready(local, fromLocalCopy: true)
            return
        }
        do {
            guard let data = try await github.file(repo: repo, path: PreviewManifest.path) else {
                recipes[repo] = .missing
                return
            }
            recipes[repo] = .ready(try JSONDecoder().decode(PreviewManifest.self, from: data), fromLocalCopy: false)
        } catch {
            recipes[repo] = .failed(error.localizedDescription)
        }
    }

    // MARK: Run loop

    /// The run a Tweak is aimed at; the next message in its bot's thread
    /// goes to that run instead of starting a new conversation turn.
    var tweakRunId: UUID?

    /// A person's decision on a run card: Approve, Cancel, Keep, Discard,
    /// Open PR, Not now. Approve starts the run on darkmux.
    func decide(_ event: RunEvent, on run: BotRun, store: BotStore) {
        // Nothing fake ever runs: a run that can't go to darkmux isn't started.
        if event == .approve, let reason = whyRunCannotStart(run) {
            if let bot = run.bot { store.append(.system, "Can't run this yet: \(reason).", to: store.conversation(for: .bot(bot.id))) }
            return
        }
        // Keep and Discard act on the files first; the card moves only when
        // darkmux has done it, and says what it did.
        if event == .keep || event == .discard, run.darkmuxWorkId != nil {
            Task { await applyOnDisk(event, to: run, store: store) }
            return
        }
        guard store.apply(event, to: run) else { return }
        if event == .approve { _ = startRealRun(run, message: run.brief ?? run.task, store: store) }
    }

    /// Runs with Keep or Discard in flight (their buttons wait).
    var deciding: Set<UUID> = []

    private func applyOnDisk(_ event: RunEvent, to run: BotRun, store: BotStore) async {
        guard run.phase == .result, !deciding.contains(run.id), let bot = run.bot,
              let workId = run.darkmuxWorkId, let connection, let token = connection.token else {
            if let bot = run.bot, connection?.token == nil {
                store.append(.system, "Can't do that yet: \(RunBlocker.unpaired.message).", to: store.conversation(for: .bot(bot.id)))
            }
            return
        }
        let thread = store.conversation(for: .bot(bot.id))
        deciding.insert(run.id)
        defer { deciding.remove(run.id) }
        do {
            if event == .keep {
                let kept = try await connection.client.keepWork(token: token, workId: workId, message: run.task)
                run.keptBranch = kept.branch
                run.keptCommit = kept.commit
                store.append(.system, RunResultText.kept(files: kept.files, branch: kept.branch, commit: kept.commit), to: thread)
            } else {
                let put = try await connection.client.discardWork(token: token, workId: workId)
                store.append(.system, RunResultText.discarded(restored: put.restored, removed: put.removed), to: thread)
            }
            store.apply(event, to: run)
        } catch {
            store.append(.system, "Couldn't \(event == .keep ? "keep" : "discard") it: \(error.localizedDescription)", to: thread)
        }
    }

    /// Every darkmux run gets the same working rules after its task, plus
    /// the repo's own hints from its `.darkmux/preview.json`, never a guess
    /// about how some other kind of project is laid out.
    nonisolated static func workBrief(_ task: String, recipe: PreviewManifest? = nil) -> String {
        let hints = recipe?.conventions.map { "\n\nAbout this repository: \($0)" } ?? ""
        return task + hints + """


            You are working in this repository (the current directory). Find the file responsible, \
            make the smallest change that does it, and change nothing else. Don't run installs, builds \
            or the dev server. If you can't find where to change, stop and say what you searched instead \
            of repeating searches. When done, list the files you changed.
            """
    }

    /// The recipe already read for a bot's repo, if any.
    func recipe(for bot: Bot) -> PreviewManifest? {
        guard let repo = bot.repoSlugs.first, case let .ready(manifest, _)? = recipes[repo] else { return nil }
        return manifest
    }

    /// darkmux refusing or not answering a submit fails the run; it is never
    /// a result to Keep.
    nonisolated static func startFailure(_ error: any Error) -> RunEvent {
        .fail(reason: "Couldn't start on darkmux", details: error.localizedDescription)
    }

    /// A Tweak re-sends the original brief, what the run changed, and the
    /// change you asked for, so the crew has the whole picture.
    static func tweakMessage(for run: BotRun, change: String) -> String {
        var parts = ["Earlier task:\n\(run.brief ?? run.task)"]
        if !run.changedFiles.isEmpty {
            parts.append("You already changed: \(run.changedFiles.joined(separator: ", ")).")
        }
        parts.append("Now change this: \(change)")
        return parts.joined(separator: "\n\n")
    }

    /// Polls a darkmux run until it ends, then posts its result (or notes
    /// that it was stopped).
    private func follow(_ run: BotRun, workId: String, token: String, client: DarkmuxClient, store: BotStore) async {
        while run.phase == .running, run.darkmuxWorkId == workId {
            try? await Task.sleep(for: .seconds(3))
            let status: DarkmuxClient.WorkStatus
            do {
                status = try await client.workStatus(token: token, workId: workId)
            } catch let error as DarkmuxClient.ClientError where error.status == 404 {
                // darkmux no longer knows this run (restarted, or it ended long ago):
                // show it as stopped rather than spinning forever.
                store.apply(.stop, to: run)
                return
            } catch {
                continue   // darkmux briefly unreachable: keep checking
            }
            switch status.status {
            case "running", "cancelling": continue
            case "cancelled": store.apply(.stop, to: run); return
            case "done":
                let report = status.finalAssistant ?? ""
                run.notes = report.isEmpty ? nil : report
                run.changedFiles = (status.changes?.files ?? []).map { f in
                    "\(f.path) +\(f.added ?? 0) −\(f.removed ?? 0)"
                }
                run.diff = status.changes?.diff
                let summary = await summarize(report: report, files: (status.changes?.files ?? []).map(\.path), botName: run.bot?.name)
                store.apply(.finish(summary: summary), to: run)
                return
            default:
                switch RunResultText.classify(error: status.error ?? "", reason: status.reason) {
                case .stopped: store.apply(.stop, to: run)
                case let .failed(why):
                    store.apply(.fail(reason: "Didn't finish: \(why)", details: RunResultText.withoutPlumbing(status.error ?? "")), to: run)
                }
                return
            }
        }
    }

    /// One or two friendly sentences in the bot's own voice about what was
    /// wrong and what changed: the on-device model when it can, else a
    /// plain template.
    private func summarize(report: String, files: [String], botName: String?) async -> String {
        let fallback = RunResultText.fallbackSummary(report: report, files: files)
        #if canImport(FoundationModels)
        guard useOnDeviceModel, onDeviceUnavailableReason == nil, !report.isEmpty else { return fallback }
        let session = LanguageModelSession(instructions: """
            You are \(botName ?? "a bot") in Mux Bot. In one or two short, friendly sentences, in the first person, \
            plain text with no markdown, say what was wrong and what you changed. Mention the file by name.
            """)
        let prompt = "Report:\n\(String(RunResultText.plain(report).prefix(1500)))\nFiles changed: \(files.joined(separator: ", "))"
        guard let line = try? await session.respond(to: prompt).content.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty, line.count < 400, !line.contains("**") else { return fallback }
        return line
        #else
        return fallback
        #endif
    }

    /// The app can't open pull requests yet (no GitHub sign-in): pass the
    /// request to the lead bot's thread, honestly, and close the card.
    func passPRToLead(_ run: BotRun, store: BotStore) {
        guard let bot = run.bot else { return }
        let workCopy = bot.workspaceName.map { " Work copy: darkmux workspace \($0) on \(bot.workspaceMachine ?? "this Mac")." } ?? ""
        store.append(.system, "From \(bot.name): open a pull request for “\(run.task)”.\(workCopy)", to: store.conversation(for: .lead))
        store.append(.system, "Passed to \(LeadBot.name).", to: store.conversation(for: .bot(bot.id)))
        store.apply(.skipPR, to: run)
    }

    /// After a relaunch, pick up runs that were still going on darkmux.
    func resumeFollowing(store: BotStore) {
        guard let connection, let token = connection.token else { return }
        let runs = (try? store.context.fetch(FetchDescriptor<BotRun>())) ?? []
        // Earlier builds stored a raw darkmux error as the result; show those as
        // a plain outcome now.
        for run in runs where run.phase == .result {
            guard run.summary.hasPrefix("darkmux reported an error") else { continue }
            let raw = String(run.summary.dropFirst("darkmux reported an error: ".count))
            run.details = RunResultText.withoutPlumbing(raw)
            switch RunResultText.classify(error: raw, reason: nil) {
            case .stopped: run.phase = .canceled
            case let .failed(why): run.phase = .failed; run.summary = "Didn't finish: \(why)"
            }
            if let bot = run.bot { store.refreshState(of: bot) }
        }
        for run in runs where run.phase == .running {
            guard let workId = run.darkmuxWorkId else { continue }
            Task { await follow(run, workId: workId, token: token, client: connection.client, store: store) }
        }
    }

    /// Stops a running run: darkmux cancels it (TERM, then KILL, and its
    /// container); the card shows it stopped.
    func stop(_ run: BotRun, store: BotStore) async {
        guard run.phase == .running else { return }
        if let workId = run.darkmuxWorkId, let connection, let token = connection.token {
            do {
                try await connection.client.cancelWork(token: token, workId: workId)
            } catch {
                if let bot = run.bot {
                    store.append(.system, "Couldn't stop it on darkmux: \(error.localizedDescription)", to: store.conversation(for: .bot(bot.id)))
                }
                return
            }
        }
        store.apply(.stop, to: run)
    }

    /// What stops a run going to darkmux right now, or nil when it can.
    func blocker(for run: BotRun) -> RunBlocker? {
        guard let bot = run.bot else { return .noCode }
        return RunBlocker.check(paired: connection?.isPaired == true && connection?.token != nil, crew: run.crew, bot: bot)
    }

    /// Why a run can't go to darkmux right now, or nil when it can.
    func whyRunCannotStart(_ run: BotRun) -> String? {
        blocker(for: run)?.message
    }

    // MARK: Live previews

    /// darkmux-run previews, by bot.
    var livePreviews: [UUID: LivePreview] = [:]

    /// The URL the preview panel shows for a bot.
    func previewURL(for bot: Bot) -> URL? {
        LivePreview.url(darkmux: livePreviews[bot.id], resource: bot.previewURL)
    }

    /// Whether a preview can be shown: darkmux can run one in the bot's work
    /// copy, or you added a preview link.
    func canPreview(_ bot: Bot) -> Bool {
        (bot.workspaceName != nil && connection?.isPaired == true) || bot.previewURL != nil
    }

    /// Has darkmux run the bot's preview, and follows it until it's ready or
    /// fails. Does nothing without a work copy or pairing (a preview link
    /// is shown as is).
    func ensurePreview(for bot: Bot) async {
        guard let name = bot.workspaceName, let connection, let token = connection.token else { return }
        if let status = livePreviews[bot.id]?.status, status != .stopped, !(status.isFailed) { return }
        livePreviews[bot.id] = LivePreview(status: .starting)
        do {
            var p = try await connection.client.startPreview(token: token, workspace: name).live
            livePreviews[bot.id] = p
            let deadline = Date().addingTimeInterval(15 * 60)
            while [.starting, .installing].contains(p.status), Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                p = try await connection.client.previewStatus(token: token, workspace: name).live
                livePreviews[bot.id] = p
            }
        } catch let error as DarkmuxClient.ClientError where error.status == 404 {
            livePreviews[bot.id] = nil   // no recipe: fall back to a preview link, if any
        } catch {
            livePreviews[bot.id] = LivePreview(status: .failed(error.localizedDescription))
        }
    }

    func stopPreview(for bot: Bot) async {
        guard let name = bot.workspaceName, let connection, let token = connection.token else { return }
        try? await connection.client.stopPreview(token: token, workspace: name)
        livePreviews[bot.id] = LivePreview(status: .stopped)
    }

    // MARK: Work copies

    enum WorkCopySetup: Equatable { case settingUp, failed(String) }
    /// Work copies being set up (or that failed), by bot.
    var workCopySetup: [UUID: WorkCopySetup] = [:]

    /// Asks darkmux for the bot's workspace on this Mac: a worktree of the
    /// folder you picked (on its own branch, from the fetched default
    /// branch), else a clone of its GitHub repo. Stores only the name.
    func setUpWorkCopy(for bot: Bot, store: BotStore, sourcePath: String? = nil) async {
        guard let connection, let token = connection.token else {
            workCopySetup[bot.id] = .failed(RunBlocker.unpaired.message)
            return
        }
        let bodyAndAccess = sourcePath.map { (body: DarkmuxClient.WorkspaceBody?.some(.init(repoURL: nil, sourcePath: $0, bot: bot.name)), release: {}) }
            ?? workspaceRequest(for: bot)
        guard let body = bodyAndAccess.body else {
            workCopySetup[bot.id] = .failed(RunBlocker.noCode.message)
            return
        }
        defer { bodyAndAccess.release() }
        workCopySetup[bot.id] = .settingUp
        do {
            let made = try await connection.client.setUpWorkspace(token: token, body)
            bot.workspaceName = made.workspace
            bot.workspaceMachine = FleetConnection.machineName
            if bot.repoSlugs.isEmpty, let repo = made.repo, let slug = GitHubIssue.repoSlug(from: repo) {
                store.addResource(.repo, "https://github.com/\(slug)", to: bot)
            }
            try? store.context.save()
            workCopySetup[bot.id] = nil
            let branch = made.branch.map { $0.isEmpty ? "" : ", branch \($0)" } ?? ""
            store.append(.system, "Work copy ready on \(FleetConnection.machineName)\(branch).", to: store.conversation(for: .bot(bot.id)))
            if let repo = bot.repoSlugs.first { recipes[repo] = nil; await loadRecipe(for: repo, workspace: made.workspace) }
        } catch {
            workCopySetup[bot.id] = .failed(error.localizedDescription)
        }
    }

    /// The request for a bot's workspace, with folder access held until
    /// `release` (the picked folder is security-scoped).
    private func workspaceRequest(for bot: Bot) -> (body: DarkmuxClient.WorkspaceBody?, release: () -> Void) {
        if let data = bot.folderBookmark, let url = Self.resolve(bookmark: data) {
            let accessing = url.startAccessingSecurityScopedResource()
            return (DarkmuxClient.WorkspaceBody(repoURL: nil, sourcePath: url.path, bot: bot.name),
                    { if accessing { url.stopAccessingSecurityScopedResource() } })
        }
        if let repo = bot.repoSlugs.first {
            return (DarkmuxClient.WorkspaceBody(repoURL: "https://github.com/\(repo)", sourcePath: nil, bot: bot.name), {})
        }
        return (nil, {})
    }

    nonisolated static func resolve(bookmark: Data) -> URL? {
        var stale = false
        #if os(macOS)
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
    }

    /// A folder you picked with the Open panel: it must be a git checkout.
    /// Its GitHub repo (from `origin`) becomes the bot's repo, and darkmux
    /// makes a worktree of it so runs never touch your own working tree.
    /// Returns a plain sentence when the folder can't be used.
    @discardableResult
    func addFolder(_ url: URL, to bot: Bot, store: BotStore) async -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard GitRemote.isRepository(url) else {
            return "\(url.lastPathComponent) isn't a git repository. Pick the top folder of a project you cloned with git."
        }
        #if os(macOS)
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        bot.folderBookmark = bookmark ?? Data()
        bot.folderName = url.lastPathComponent
        bot.workspaceName = nil
        if let slug = GitRemote.originSlug(of: url), !bot.repoSlugs.contains(slug) {
            store.addResource(.repo, "https://github.com/\(slug)", to: bot)
        }
        try? store.context.save()
        guard bookmark != nil else { return "I couldn't keep access to \(url.lastPathComponent). Pick it again." }
        if connection?.isPaired == true { await setUpWorkCopy(for: bot, store: store) }
        return nil
    }

    /// Sends the run to darkmux when this app is paired, the crew role maps
    /// to a darkmux role, and the bot has a workspace on this Mac.
    /// Returns false otherwise.
    private func startRealRun(_ run: BotRun, message: String, store: BotStore) -> Bool {
        guard let connection, let token = connection.token,
              let role = run.crew.darkmuxRole, let bot = run.bot,
              let workspace = bot.workspaceName else { return false }
        let thread = store.conversation(for: .bot(bot.id))
        Task { @MainActor in
            do {
                // darkmux picks the profile for this role (its role binding, else
                // the default) and checks it against what the owner granted.
                let (workId, profile) = try await connection.client.submitWork(token: token, role: role,
                                                                               message: Self.workBrief(message, recipe: recipe(for: bot)),
                                                                               profile: nil, workspace: workspace)
                run.darkmuxWorkId = workId
                store.append(.system, "Running on darkmux: \(role)\(profile.map { " on \($0)" } ?? "").", to: thread)
                await follow(run, workId: workId, token: token, client: connection.client, store: store)
            } catch {
                store.apply(Self.startFailure(error), to: run)
            }
        }
        return true
    }

    /// Sends a follow-up to the same run (and, once wired, the same worktree).
    func tweak(_ request: String, run: BotRun, store: BotStore) {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let bot = run.bot else { return }
        store.append(.user, text, to: store.conversation(for: .bot(bot.id)))
        tweakRunId = nil
        if let reason = whyRunCannotStart(run) {
            store.append(.system, "Can't run this yet: \(reason).", to: store.conversation(for: .bot(bot.id)))
            return
        }
        guard store.apply(.tweak, to: run) else { return }
        _ = startRealRun(run, message: Self.tweakMessage(for: run, change: text), store: store)
    }



    /// Drops any sentence that names a tool or tells the user to use one.
    nonisolated static func withoutToolTalk(_ reply: String) -> String {
        let banned = ["listopenissues", " tool", "tool "]
        let sentences = reply.split(omittingEmptySubsequences: true) { ".!?\n".contains($0) }
        let kept = sentences.filter { s in !banned.contains { s.lowercased().contains($0) } }
        guard kept.count < sentences.count else { return reply }
        let text = kept.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ". ")
        return text.isEmpty ? "Let me check that properly." : text + "."
    }




    /// Approve or Cancel on an action card. Each card is decided once.
    func resolve(_ card: ChatMessage, approve: Bool, store: BotStore) {
        guard card.kind == .actionCard, card.actionState == .waiting, let action = card.action else { return }
        let chat: ChatContext = card.conversation?.roleId.map { .bot($0) } ?? .lead
        card.actionState = approve ? .approved : .canceled
        defer { try? store.context.save() }
        guard approve else { return }
        let from = chat.botId.flatMap { store.bot(id: $0)?.name } ?? LeadBot.name
        let note: String
        switch action {
        case let .handOff(toId, toName, task):
            guard let target = store.bot(id: toId) else { return }
            store.handOff(task: task, from: from, to: target)
            note = "Handed to \(toName): \(task)"
        case let .createBot(draft):
            store.add(name: draft.name, instructions: draft.instructions, systemImage: draft.systemImage)
            note = "Added bot \(draft.name)."
        case let .dispatch(crew, task):
            guard let bot = chat.botId.flatMap(store.bot(id:)) else { return }
            store.proposeRun(task: task, crew: crew, on: bot)
            return
        case let .addResource(kind, value):
            guard let bot = chat.botId.flatMap(store.bot(id:)) else { return }
            store.addResource(kind, value, to: bot)
            note = "Added \(kind.label.lowercased()): \(value)"
        }
        store.append(.system, note, to: store.conversation(for: chat))
    }

    private func onDeviceTurn(for request: String, speaker: BotSummary?, bots: [BotSummary], repos: [BotRepo],
                              compact: Bool = false) async throws -> BotTurn? {
        #if canImport(FoundationModels)
        let others = bots.filter { $0.id != speaker?.id }
        let lower = request.lowercased()
        let wantsIssues = FallbackBrain.isIssueQuestion(lower) || lower.contains("issue")
        let issueTool = OpenIssuesTool(repos: repos, client: github)
        let tools: [any Tool] = compact || repos.isEmpty || !wantsIssues ? [] : [issueTool]
        let session = LanguageModelSession(tools: tools, instructions: Self.instructions(
            for: request, speaker: speaker, bots: bots, compact: compact))
        do {
            var g: GeneratedTurn
            do {
                g = try await session.respond(to: request, generating: GeneratedTurn.self).content
            } catch LanguageModelSession.GenerationError.decodingFailure {
                // The model sometimes answers in prose instead of the
                // structure; one retry, then let the caller fall back.
                do {
                    g = try await session.respond(to: request, generating: GeneratedTurn.self).content
                } catch LanguageModelSession.GenerationError.decodingFailure {
                    return nil
                }
            }
            // Never trust an answer about issues that didn't check GitHub.
            if FallbackBrain.isIssueQuestion(request.lowercased()) && issueTool.counter.count == 0 { return nil }
            g.reply = Self.withoutToolTalk(g.reply)
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
            throw error
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
