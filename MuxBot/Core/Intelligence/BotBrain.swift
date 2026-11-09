import Foundation
import SwiftData

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The lead bot on Home: the guide (setup, first bot, help) that hands work
/// to the right bot but never starts it. Placeholder name:
/// rename it here and only here.
enum LeadBot {
    static let name = "Mux Bot"
    static let systemImage = "crown"
    static let persona = "You're the guide: you help people set up Mux Bot (darkmux, pairing, models, GitHub), make their first bot from a repo, and answer questions about Mux Bot and darkmux from its help. When the help doesn't say, you say you don't know. You don't start work yourself: work happens in a bot's thread. Short, friendly, plain."
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
    /// A repo link or folder path the bot starts with.
    var resource: String? = nil
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
    /// Continue a run that just finished with a follow-up (a Tweak).
    case tweak(runId: UUID, change: String)
    /// Write a preview recipe into your own checkout and the next PR.
    case setUpPreview(PreviewSetup)
    /// Write a PLAYBOOK.md into your own checkout and the next PR.
    case setUpPlaybook(PlaybookSetup)
}

extension BotAction {
    /// Cards that write into your checkout bring their own Approve (it
    /// needs your folder first).
    var hasOwnButtons: Bool {
        switch self {
        case .setUpPreview, .setUpPlaybook: true
        default: false
        }
    }
}

/// One bot turn: what it says, and what it proposes to do.
/// A run waiting on one answer: the answer completes its brief.
struct PendingDispatch {
    var task: String
    var crew: CrewRole
    var check: LayoutCheck.Spec? = nil
    var brief: @MainActor (String) -> String
}

struct BotTurn: Sendable, Equatable {
    var reply: String
    var action: BotAction?
    /// The crew's brief for a `.dispatch` action (an issue's page, element
    /// and expected result); nil sends the task text alone.
    var brief: String? = nil
    /// What to measure after that run (its done-when).
    var check: LayoutCheck.Spec? = nil
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
        let padded = " \(lower.replacingOccurrences(of: "?", with: " ")) "
        let asks = ["issue", "ticket", "bug", "prs", "to fix", "needs fixing", "need fixing", "broken"]
        // "PR 9 is still not right" names one PR: it's about that PR, not a list.
        let asksAboutPRs = Intent.prReference(in: lower) == nil && ["pull request", " pr "].contains { padded.contains($0) }
        return (asks.contains { padded.contains($0) } || asksAboutPRs)
            && !["fix the", "fix this", "build", "implement"].contains { lower.contains($0) }
    }

    /// Words that say "issues" rather than naming a bot (ignored when
    /// matching a bot by its persona).
    static let issueWords: Set<String> = ["bugs", "issue", "issues", "fixes", "fixing", "open", "tickets", "ticket", "broken", "anything", "there"]

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

@Generable(description: "Two short parts of a project's playbook")
struct DraftedPlaybook {
    @Guide(description: "Two or three sentences to the assistant, starting \"You look after\" and the project's name: what the project is and how to work on it (make only the change asked for, follow the project's conventions, say in plain words what changed)")
    var persona: String
    @Guide(description: "One short paragraph: the project's stack and where things live (folders, main files, how styles and pages are organized), only as the README states them; empty if the README doesn't say")
    var conventions: String
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
    /// A dispatch waiting on one answer from you, by bot: "What's still
    /// wrong?" about a PR, or "What should change?" about a measured issue.
    /// Your next message answers it; anything else drops it.
    var pendingAnswers: [UUID: PendingDispatch] = [:]
    /// Measures pages for visual issues (an offscreen web view in the app).
    var layoutProbe: (any LayoutProbing)? {
        get { runs.layoutProbe }
        set { runs.layoutProbe = newValue }
    }
    /// Off in tests, so turns are deterministic keyword-fallback turns.
    var useOnDeviceModel = true { didSet { runs.useOnDeviceModel = useOnDeviceModel } }
    var github: any GitHubClient = RESTGitHubClient() { didSet { runs.github = github } }
    /// Runs, work copies and previews.
    let runs = RunCoordinator()
    /// Your checkout of a bot's repo (tests); else its bookmark.
    @ObservationIgnored var checkoutFolder: ((Bot) -> URL?)?
    /// Reads a checkout's README (tests); else the disk.
    @ObservationIgnored var readmeReader: ((URL) -> String?)?
    /// Drafts a playbook's persona and conventions (tests); else the on-device model.
    @ObservationIgnored var playbookDrafter: ((String, String, String?) async -> (persona: String, conventions: String)?)?
    /// Reads a checkout's package.json and root names (tests); else the disk.
    @ObservationIgnored var checkoutReader: ((URL) -> (packageJSON: String?, files: Set<String>))?
    /// Mux Bot as a guide, in its own thread.
    let guide = LeadGuide()
    /// The pairing with darkmux on this Mac; when paired, approved runs go
    /// to darkmux.
    var connection: FleetConnection? {
        get { runs.connection }
        set { runs.connection = newValue }
    }
    var notifier: NotificationService? {
        get { runs.notifier }
        set { runs.notifier = newValue }
    }
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
        } ?? "You are \(LeadBot.name), the lead bot in Mux Bot. \(LeadBot.persona) When the user wants work done, hand it to the bot whose theme or resources fit; you never dispatch it yourself."
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
    var onDeviceUnavailableReason: String? { Self.modelUnavailableReason }

    nonisolated static var modelUnavailableReason: String? {
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
            guard !withRepo.isEmpty else { return BotTurn(reply: "None of your bots has a GitHub repo yet.", action: nil) }
            // A bot named (or clearly meant): its repo. Otherwise every bot's.
            let meaningful = FallbackBrain.tokens(lower).filter { !FallbackBrain.issueWords.contains($0) }.joined(separator: " ")
            let pick = withRepo.first { lower.contains($0.name.lowercased()) }
                ?? (meaningful.isEmpty ? nil : FallbackBrain.bestMatch(for: meaningful, in: withRepo))
            target = pick.flatMap { b in repos.first { $0.bot == b.name } }
            if target == nil { return await allReposIssuesTurn(repos: repos, asked: lower) }
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

    /// Every bot's repo: open issues (with the open PR that fixes each) per
    /// bot, checked on GitHub first. Nothing proposed: name a bot to act.
    private func allReposIssuesTurn(repos: [BotRepo], asked lower: String) async -> BotTurn {
        var parts: [String] = []
        for ref in repos {
            do {
                let turn = FallbackBrain.issuesTurn(try await github.openIssues(repo: ref.repo), repo: ref.repo, asked: lower)
                let body = turn.reply.components(separatedBy: "\n").filter { !$0.hasPrefix("Fix #") && !$0.hasPrefix("Open on") }
                parts.append("\(ref.bot) (\(ref.repo)):\n" + body.joined(separator: "\n"))
            } catch {
                parts.append("\(ref.bot) (\(ref.repo)): couldn't read issues (\(error.localizedDescription)).")
            }
        }
        return BotTurn(reply: parts.joined(separator: "\n\n") + "\n\nName a bot to fix one, like “fix #8 on \(repos[0].bot)”.", action: nil)
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
            let pageFile = context.botId.flatMap(store.bot(id:)).flatMap(runs.recipes.recipe(for:))?.pageFile
            store.append(.assistant, ElementExplainer.explain(element, pageFile: pageFile), to: conversation)
            return
        }
        let intent = explicit ?? Intent.infer(text, hasElement: element != nil)
        message.intentRaw = intent?.rawValue
        store.save()

        // Mux Bot's thread: the guide answers setup, first-bot, settings and
        // help questions (`Guide.isEnabled` cuts it).
        if speaker == nil, Guide.isEnabled, element == nil, explicit == nil || explicit == .ask,
           intent == nil || intent == .ask, let route = GuideRoute.route(text),
           // A question about one of your bots is the lead bot's, not the help's.
           route != .help || !bots.contains(where: { text.lowercased().contains($0.name.lowercased()) }) {
            isThinking = true
            defer { isThinking = false }
            await guide.respond(route, to: text, store: store, brain: self)
            return
        }

        isThinking = true
        defer { isThinking = false }
        fallbackNote = nil

        // A bot reads its own repos; the lead bot reads every bot's.
        let repos = (speaker.map { [$0] } ?? bots).flatMap { bot in
            bot.resources.compactMap(GitHubIssue.repoSlug(from:)).map { BotRepo(bot: bot.name, repo: $0) }
        }
        let bot = context.botId.flatMap(store.bot(id:))
        let target = element.map { " (`\($0.selector)` on \($0.url))" } ?? ""
        // A skill by its name (its chip): one question for the specifics; the
        // answer becomes the run, with the skill's notes in its brief.
        if let bot, explicit == nil, let skill = bot.skills.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) {
            message.intentRaw = Intent.fix.rawValue
            pendingAnswers[bot.id] = PendingDispatch(task: skill.name, crew: .coder) { "\(skill.name): \($0)" }
            store.append(.assistant, skill.question, to: conversation)
            return
        }
        // The answer to the bot's one question becomes the run it was about.
        if let bot, let pending = pendingAnswers.removeValue(forKey: bot.id), explicit == nil || explicit == .fix,
           Intent.issueNumber(in: text) == nil, !Self.isDismissal(text), !WorkStatus.isWorkQuestion(text.lowercased()) {
            message.intentRaw = Intent.fix.rawValue
            store.append(.assistant, "I'll send this to the \(pending.crew.name) crew. Approve to dispatch.", to: conversation)
            let run = store.proposeRun(task: pending.task, crew: pending.crew, on: bot, brief: pending.brief(text + target))
            runs.checkSpecs[run.id] = pending.check
            await runs.chooseProfile(for: run)
            return
        }
        // "PR 9 is still not right": about that PR, never the open-issues list
        // or an older run. Read it first, then ask what's wrong (or propose).
        if let bot, explicit == nil || explicit == .fix, let complaint = Intent.prComplaint(in: text),
           let repo = repos.first?.repo {
            message.intentRaw = Intent.fix.rawValue
            let pr: PullRequestInfo?
            do {
                pr = try await github.pullRequest(repo: repo, number: complaint.number)
            } catch {
                store.append(.assistant, "I couldn't read PR #\(complaint.number) on GitHub: \(error.localizedDescription)", to: conversation)
                return
            }
            guard let pr else {
                store.append(.assistant, "I can't find pull request #\(complaint.number) on \(repo).", to: conversation)
                return
            }
            if let whatsWrong = complaint.whatsWrong.map({ $0 + target }) ?? element.map({ _ in "this element\(target)" }) {
                proposePRFollowUp(pr, repo: repo, whatsWrong: whatsWrong, bot: bot, store: store, conversation: conversation)
            } else {
                pendingAnswers[bot.id] = PendingDispatch(task: Self.prFollowUpTask(pr, repo: repo), crew: .coder) {
                    Self.prFollowUpBrief(pr, repo: repo, whatsWrong: $0)
                }
                store.append(.assistant, "PR #\(pr.number) “\(pr.title)” (\(pr.status)) changed \(Self.fileList(pr.files)). "
                             + "What's still wrong? Say what you see, or point at it in the preview (Pick).", to: conversation)
            }
            return
        }
        if speaker == nil, let intent, [.bug, .fix, .review].contains(intent) {
            store.append(.assistant, "Open the bot for that project to report bugs or send work to its crew.", to: conversation)
            return
        }
        // Right after a run finishes, a remark about it continues that run (a
        // Tweak), never a new dispatch picked from older history.
        // Only a change request: never a question, an ask, a bug report, a
        // pick from the preview, or "thanks".
        if let bot, Self.isChangeRequest(text, intent: intent, element: element), Intent.issueNumber(in: text) == nil,
           !WorkStatus.isWorkQuestion(text.lowercased()),
           let last = (bot.runs ?? []).max(by: { $0.createdAt < $1.createdAt }),
           [.result, .failed, .canceled].contains(last.phase),
           // A proposal canceled before it ever ran has nothing to follow up.
           last.startedAt != nil,
           Date().timeIntervalSince(last.finishedAt ?? last.createdAt) < 6 * 3600 {
            if last.phase == .result {
                // Your reply after a result changes that same run (a Tweak).
                await rerun(last, change: text, store: store)
            } else {
                // A stopped or failed run runs again only after Approve.
                store.append(.assistant, "That sounds like a follow-up to “\(last.task)”. Run it again with that change?", to: conversation)
                store.proposeAction(.tweak(runId: last.id, change: text), in: context)
            }
            return
        }
        // "What's running?", "what needs me?": answered from the runs, never guessed.
        if intent == nil || intent == .ask, WorkStatus.isWorkQuestion(text.lowercased()) {
            let runs = speaker == nil ? store.allBots().flatMap { $0.runs ?? [] } : (bot?.runs ?? [])
            var reply = WorkStatus.summary(runs: runs)
            let nudges = WorkStatus.nudges(runs: runs)
            if !nudges.isEmpty { reply += "\n\n" + nudges.joined(separator: "\n") }
            message.intentRaw = Intent.ask.rawValue
            store.append(.assistant, reply, to: conversation)
            return
        }
        switch intent {
        case .bug?:
            // Never let a model that can't see the page judge it: measure it
            // and draft an issue.
            await draftBug(text, element: element, repo: repos.first?.repo, bot: bot, store: store, conversation: conversation)
            return
        case .fix?, .review?:
            let crew: CrewRole = intent == .fix ? .coder : .reviewer
            var task = text + target
            var brief: String?
            var check: LayoutCheck.Spec?
            // "fix #8" or an issue link: dispatch that issue, with its body as the brief.
            if let number = Intent.issueNumber(in: text), let repo = repos.first?.repo {
                let issue = try? await github.issue(repo: repo, number: number)
                guard let issue else {
                    store.append(.assistant, "I can't find #\(number) on \(repo).", to: conversation)
                    return
                }
                guard issue.state != "closed" else {
                    store.append(.assistant, "#\(number) is already closed on \(repo).", to: conversation)
                    return
                }
                switch await plan(issue: issue, repo: repo, crew: crew, bot: bot) {
                case let .dispatch(planned, plannedBrief, plannedCheck):
                    task = planned
                    brief = plannedBrief
                    check = plannedCheck
                case let .ask(question, pending):
                    if let bot { pendingAnswers[bot.id] = pending }
                    store.append(.assistant, question, to: conversation)
                    return
                case let .cannot(why):
                    store.append(.assistant, why, to: conversation)
                    return
                }
            }
            store.append(.assistant, "I'll send this to the \(crew.name) crew. Approve to dispatch.", to: conversation)
            if let bot {
                let run = store.proposeRun(task: task, crew: crew, on: bot, brief: brief)
                runs.checkSpecs[run.id] = check
                await runs.chooseProfile(for: run)
            }
            return
        case .issues?:
            var turn = await issuesTurn(for: text, repos: repos, lead: speaker == nil, bots: bots)
            // An offered fix carries the issue's brief; one that doesn't say
            // where is asked about instead of sent to search blind.
            if case let .dispatch(crew, task)? = turn.action, let number = Intent.issueNumber(in: task), let repo = repos.first?.repo,
               let issue = try? await github.issue(repo: repo, number: number) {
                switch await plan(issue: issue, repo: repo, crew: crew, bot: bot) {
                case let .dispatch(_, brief, check):
                    turn.brief = brief
                    turn.check = check
                case let .ask(question, pending):
                    turn.action = nil
                    if let bot { pendingAnswers[bot.id] = pending }
                    turn.reply = turn.reply.replacingOccurrences(of: "Fix #\(number) with Coder?", with: question)
                case let .cannot(why):
                    turn.action = nil
                    turn.reply = turn.reply.replacingOccurrences(of: "Fix #\(number) with Coder?", with: why)
                }
            }
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
        // Never a dispatch built from a bare "Fix PR #9": issues are read first.
        if case let .dispatch(_, task)? = result.action, Self.isBareReference(task) {
            result.action = nil
            result.reply = "Which one? Say “fix #N” and I'll read the issue on GitHub first."
        }
        apply(result, context: context, store: store, conversation: conversation)
    }

    enum IssuePlan {
        case dispatch(task: String, brief: String, check: LayoutCheck.Spec? = nil)
        /// One short question first; the answer completes the brief.
        case ask(String, PendingDispatch)
        case cannot(String)
    }

    /// How an issue becomes a run: its brief (never a bare title), measured
    /// in the preview first when it's visual. If the issue and the numbers
    /// still don't say what to change, one question instead.
    private func plan(issue: GitHubIssue, repo: String, crew: CrewRole, bot: Bot?) async -> IssuePlan {
        let task = "\(crew == .coder ? "Fix" : "Review") #\(issue.number): \(issue.title) (\(repo))"
        guard let base = IssueBrief.compose(issue: issue, repo: repo, crew: crew,
                                            pageFile: bot.flatMap(runs.recipes.recipe(for:))?.pageFile) else {
            // Never send a model to search blind on a title.
            return .cannot("#\(issue.number) doesn't say where. Which page and element? Point at it in the preview (Pick), then say what's wrong.")
        }
        guard crew == .coder, LayoutMeasure.isVisual(issue), let bot else { return .dispatch(task: task, brief: base) }
        guard let probe = layoutProbe, let root = runs.previewURL(for: bot) else {
            return .dispatch(task: task, brief: base + "\nNot measured: the preview isn't running.")
        }
        let parts = IssueBrief.parse(issue.body ?? "")
        let url = URL(string: String((parts.page ?? "/").drop { $0 == "/" }), relativeTo: root)?.absoluteURL ?? root
        let widths = LayoutMeasure.widths(forViewport: parts.viewport)
        let facts = await probe.measure(url: url, widths: widths)
        guard !facts.isEmpty else { return .dispatch(task: task, brief: base + "\nNot measured: the preview page didn't load.") }
        let focus = parts.viewport ?? widths[0]
        let measured = LayoutMeasure.summarize(facts, focus: focus)
        let brief = Self.withMeasurements(base, measured)
        let check = LayoutCheck.spec(from: measured, before: facts, focus: focus, page: url)
        if !measured.foundProblem, measured.layoutSwitch == nil, parts.expected == nil {
            let question = "At \(focus)px I measured nothing wider than the screen and no section without side padding. What should change?"
            return .ask(question, PendingDispatch(task: task, crew: crew, check: check) { brief + "\nWhat should change: \($0)" })
        }
        return .dispatch(task: task, brief: brief, check: check)
    }

    /// Runs `run` again with `change`: a finished run continues as a Tweak,
    /// a stopped or failed one is sent again (after Approve already given).
    /// An issue run's brief is rebuilt from the issue, never just its title.
    /// `nextModel`: the done-when wasn't met, so it runs on the next model
    /// the app may use; otherwise it keeps the model it ran on.
    func rerun(_ run: BotRun, change: String, store: BotStore, nextModel: Bool = false, model: String? = nil) async {
        let plan = await rerunPlan(for: run, change: change)
        if run.phase == .result {
            runs.runChecks[run.id] = nil
            if let check = plan?.check ?? runs.checkSpecs[run.id] { runs.checkSpecs[run.id] = check }
            if nextModel { await runs.chooseProfile(for: run, next: true) }
            if let model { runs.override(run, with: model) }
            runs.tweak(change, run: run, store: store, echo: false, message: plan?.brief)
        } else if let bot = run.bot {
            let again = store.proposeRun(task: run.task, crew: run.crew, on: bot,
                                         brief: plan?.brief ?? RunCoordinator.tweakMessage(for: run, change: change))
            runs.checkSpecs[again.id] = plan?.check
            if nextModel {
                await runs.chooseProfile(for: again, next: true, after: runs.profile(for: run))
            } else {
                runs.runProfiles[again.id] = runs.profile(for: run)
            }
            if let model { runs.override(again, with: model) }
            runs.decide(.approve, on: again, store: store)
        }
    }

    /// For a run made from a GitHub issue ("Fix #10: … (owner/repo)"): the
    /// issue's brief, measured in the preview when it's visual, with what
    /// it already changed and your words. nil for any other run (it keeps
    /// "Earlier task / Now change this").
    func rerunBrief(for run: BotRun, change: String) async -> String? {
        await rerunPlan(for: run, change: change)?.brief
    }

    /// The rebuilt brief and the check that goes with it.
    func rerunPlan(for run: BotRun, change: String) async -> (brief: String, check: LayoutCheck.Spec?)? {
        guard let number = Intent.issueNumber(in: run.task),
              let repo = run.task.range(of: #"\(([\w.-]+/[\w.-]+)\)$"#, options: .regularExpression)
                .map({ String(run.task[$0].dropFirst().dropLast()) }),
              let issue = try? await github.issue(repo: repo, number: number) else { return nil }
        let base: String
        var check: LayoutCheck.Spec?
        switch await plan(issue: issue, repo: repo, crew: run.crew, bot: run.bot) {
        case let .dispatch(_, brief, c): base = brief; check = c
        case let .ask(_, pending): base = pending.brief("").replacingOccurrences(of: "\nWhat should change: ", with: ""); check = pending.check
        case .cannot: return nil
        }
        var parts = [base]
        if !run.changedFiles.isEmpty { parts.append("You already changed: \(run.changedFiles.joined(separator: ", ")).") }
        parts.append("What should change: \(change)")
        return (parts.joined(separator: "\n"), check)
    }

    /// The measured block (and the likely file from the matched @media
    /// rules) before "Expected", and a concrete "Done when".
    nonisolated static func withMeasurements(_ brief: String, _ m: LayoutMeasure.Measured) -> String {
        var lines = brief.components(separatedBy: "\n")
        var insert = [LayoutMeasure.block(m)]
        if let file = m.likelyFile {
            if m.switchLead != nil, let i = lines.firstIndex(where: { $0.hasPrefix("Likely file:") }) {
                // The switching rule is in the stylesheet: check that first;
                // the page component is only somewhere else to look.
                let page = lines[i].dropFirst("Likely file: ".count).replacingOccurrences(of: " (check it first)", with: "")
                lines[i] = "Likely file: \(file) (check it first)"
                insert.append("Also look at: \(page)")
            } else if m.switchLead != nil {
                insert.append("Likely file: \(file) (check it first)")
            } else {
                insert.append(lines.contains { $0.hasPrefix("Likely file:") } ? "Also likely: \(file) (its @media rules)" : "Likely file: \(file) (its @media rules)")
            }
        }
        let at = lines.firstIndex { $0.hasPrefix("Expected:") } ?? lines.endIndex
        lines.insert(contentsOf: insert, at: at)
        if let done = m.doneWhen, let i = lines.firstIndex(where: { $0.hasPrefix("Done when:") }) {
            lines[i] = "Done when: \(done)"
        }
        // A measured layout switch decides the change: lead with it, and keep
        // the issue's own Expected only as secondary (it can point elsewhere).
        if let lead = m.switchLead {
            if let i = lines.firstIndex(where: { $0.hasPrefix("Expected:") }) {
                lines[i] = "The issue also says (secondary; the measurement above decides):" + lines[i].dropFirst("Expected:".count)
            }
            lines.insert("Start here (measured in the preview; this decides the change): \(lead)", at: min(1, lines.count))
        }
        return lines.joined(separator: "\n")
    }

    /// A Coder dispatch card for what's still wrong after a PR, citing it.
    private func proposePRFollowUp(_ pr: PullRequestInfo, repo: String, whatsWrong: String, bot: Bot,
                                   store: BotStore, conversation: ChatConversation) {
        store.append(.assistant, "I'll send this to the \(CrewRole.coder.name) crew. Approve to dispatch.", to: conversation)
        let run = store.proposeRun(task: Self.prFollowUpTask(pr, repo: repo), crew: .coder, on: bot,
                                   brief: Self.prFollowUpBrief(pr, repo: repo, whatsWrong: whatsWrong))
        Task { await runs.chooseProfile(for: run) }
    }

    nonisolated static func prFollowUpTask(_ pr: PullRequestInfo, repo: String) -> String {
        "Follow up on PR #\(pr.number): \(pr.title) (\(repo))"
    }

    nonisolated static func prFollowUpBrief(_ pr: PullRequestInfo, repo: String, whatsWrong: String) -> String {
        var lines = ["Follow up on PR #\(pr.number) in \(repo) (\(pr.status)): \(pr.title)."]
        if !pr.files.isEmpty { lines.append("It changed: \(pr.files.prefix(20).joined(separator: ", ")) (look there first).") }
        lines.append("What's still wrong: \(whatsWrong)")
        lines.append("Done when: that's fixed, with no other visual change.")
        return lines.joined(separator: "\n")
    }

    /// "a.tsx and b.css", or "a, b, c and 4 more files".
    nonisolated static func fileList(_ files: [String]) -> String {
        switch files.count {
        case 0: "no files"
        case 1: files[0]
        case 2...4: files.dropLast().joined(separator: ", ") + " and " + files.last!
        default: files.prefix(3).joined(separator: ", ") + " and \(files.count - 3) more files"
        }
    }

    /// "thanks", "never mind": not an answer to "What's still wrong?".
    /// A message that asks for a change: no intent or Fix, not a question,
    /// not about a picked element, not a dismissal.
    nonisolated static func isChangeRequest(_ text: String, intent: Intent?, element: PickedElement?) -> Bool {
        guard intent == nil || intent == .fix, element == nil, !isDismissal(text) else { return false }
        return !GuideRoute.isQuestion(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated static func isDismissal(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["thanks", "thank you", "ok", "okay", "never mind", "nevermind", "cancel", "no", "nope", "forget it"].contains(lower)
    }

    private func apply(_ result: BotTurn, context: ChatContext, store: BotStore, conversation: ChatConversation) {
        store.append(.assistant, result.reply, to: conversation)
        switch result.action {
        case let .dispatch(crew, task)?:
            // Dispatches become a card in the thread, not a bar card.
            if let bot = context.botId.flatMap(store.bot(id:)) {
                let run = store.proposeRun(task: task, crew: crew, on: bot, brief: result.brief)
                runs.checkSpecs[run.id] = result.check
                Task { await runs.chooseProfile(for: run) }
            }
        case let action?:
            store.proposeAction(action, in: context)
        case nil:
            break
        }
    }

    // MARK: Bug reports

    private func draftBug(_ text: String, element: PickedElement?, repo: String?, bot: Bot?, store: BotStore, conversation: ChatConversation) async {
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
        // The layout around the reported width, measured in the preview: the
        // switch between presets, its rule and file. No model judges it.
        var layout: LayoutMeasure.Measured?
        if let probe = layoutProbe, let bot, let root = runs.previewURL(for: bot), let width = facts?.viewport {
            let page = facts?.url ?? "/"
            let url = URL(string: String(page.drop { $0 == "/" }), relativeTo: root)?.absoluteURL ?? root
            let got = await probe.measure(url: url, widths: LayoutMeasure.widths(around: width))
            if !got.isEmpty { layout = LayoutMeasure.summarize(got, focus: width) }
        }
        draft.facts += layout?.lines ?? []
        draft.likelyPlace = layout?.likelyPlace
        // Expected is what you should see: from the measurement when it says,
        // else the model's line only if it names no fix or mechanism.
        if let done = layout?.doneWhen {
            draft.expected = done.capitalizedFirst
        } else if let line = await expectedLine(for: text), BugReport.isOutcomeOnly(line) {
            draft.expected = line
        }
        if let json = try? JSONEncoder().encode(draft), let body = String(data: json, encoding: .utf8) {
            store.append(.assistant, body, kind: .bugCard, to: conversation)
        }
    }

    /// One sentence on the expected behavior, written by the on-device model
    /// from the user's words; nil when the model isn't available.
    private func expectedLine(for report: String) async -> String? {
        #if canImport(FoundationModels)
        guard useOnDeviceModel, onDeviceUnavailableReason == nil, !report.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: "You turn a bug description into one short sentence describing what the person should see on the page when it works. Describe only the visible result. Never name a cause, a fix, code, CSS, timing or settings. Reply with only that sentence.")
        let line = try? await session.respond(to: report).content.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
        #else
        return nil
        #endif
    }

    /// "Fix PR #9", "fix #8", "Review #12": a number with nothing to act on.
    nonisolated static func isBareReference(_ task: String) -> Bool {
        task.range(of: #"^\s*(fix|review)\s+(pr\s+|issue\s+)?#?\d+\s*[.!]?\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Drops any sentence that names a tool or tells the user to use one.
    nonisolated static func withoutToolTalk(_ reply: String) -> String {
        let banned = ["listopenissues", " tool", "tool ", "call a function", "function call", " api", "api "]
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
        defer { store.save() }
        guard approve else { return }
        let from = chat.botId.flatMap { store.bot(id: $0)?.name } ?? LeadBot.name
        let note: String
        switch action {
        case let .handOff(toId, toName, task):
            guard let target = store.bot(id: toId) else { return }
            store.handOff(task: task, from: from, to: target)
            note = "Handed to \(toName): \(task)"
        case let .createBot(draft):
            let bot = store.add(name: draft.name, instructions: draft.instructions, systemImage: draft.systemImage)
            bot.look = BotLook.suggested(for: draft.name)
            if let value = draft.resource {
                let kind = ResourceKind.guess(for: value)
                store.addResource(ResourceKind.addable.contains(kind) ? kind : .note, value, to: bot)
            }
            note = "Added bot \(draft.name)."
        case let .dispatch(crew, task):
            guard let bot = chat.botId.flatMap(store.bot(id:)) else { return }
            let run = store.proposeRun(task: task, crew: crew, on: bot)
            Task { await runs.chooseProfile(for: run) }
            return
        case let .addResource(kind, value):
            guard let bot = chat.botId.flatMap(store.bot(id:)) else { return }
            store.addResource(kind, value, to: bot)
            note = "Added \(kind.label.lowercased()): \(value)"
        case let .setUpPreview(setup):
            // The card wrote the file into your checkout before approving
            // (it needed your OK on the folder); here it's kept for the PR
            // and the preview starts from it once, to check it.
            guard let bot = chat.botId.flatMap(store.bot(id:)), let data = setup.recipeData else { return }
            LocalBotState.shared.update(bot.id) { $0.prFiles = ($0.prFiles ?? [:]).merging([PreviewSetup.path: data]) { $1 } }
            store.append(.system, String(localized: "Wrote \(PreviewSetup.path) into \(setup.folderName), uncommitted. It goes into this bot's next pull request too. Starting the preview to check it…"),
                         to: store.conversation(for: chat))
            Task { await checkPreview(bot, store: store) }
            return
        case let .setUpPlaybook(setup):
            // Written into your checkout by the card; kept for the PR, and
            // the bot's skills and persona become the approved ones.
            guard let bot = chat.botId.flatMap(store.bot(id:)), let playbook = setup.parsed else { return }
            LocalBotState.shared.update(bot.id) { $0.prFiles = ($0.prFiles ?? [:]).merging([PlaybookSetup.path: setup.data]) { $1 } }
            bot.skills = playbook.skills
            bot.instructions = StartProject.instructions(playbook, answers: .init(name: bot.name, purpose: setup.purpose), name: bot.name)
            note = String(localized: "Wrote \(PlaybookSetup.path) into \(setup.folderName), uncommitted, and I now use its skills. It goes into this bot's next pull request too.")
        case let .tweak(runId, change):
            guard let run = store.run(id: runId) else { return }
            // A finished run continues as a Tweak; one that was stopped or
            // failed is sent again with the change. An issue run's brief is
            // rebuilt from the issue first (GitHub, the preview), so async.
            Task { await rerun(run, change: change, store: store) }
            return
        }
        store.append(.system, note, to: store.conversation(for: chat))
    }

    /// After a recipe is written: start the preview once and say how it went.
    func checkPreview(_ bot: Bot, store: BotStore) async {
        runs.livePreviews[bot.id] = nil
        runs.noRecipe.remove(bot.id)
        await runs.ensurePreview(for: bot)
        let thread = store.conversation(for: .bot(bot.id))
        switch runs.livePreviews[bot.id]?.status {
        case .ready?: store.append(.system, String(localized: "The preview started from the new recipe."), to: thread)
        case let .failed(why)?: store.append(.system, String(localized: "The preview didn't start from the new recipe: \(why). Fix the file in your checkout and open the preview again."), to: thread)
        default: store.append(.system, String(localized: "darkmux didn't start the preview from it: \(runs.noRecipe.contains(bot.id) ? String(localized: "it still finds no recipe in your checkout") : String(localized: "it isn't ready yet")). Open the preview to try again."), to: thread)
        }
    }

    /// A project with no PLAYBOOK.md of its own: offer one (general skills,
    /// with the on-device model's draft of the persona and conventions from
    /// the README when it's available) on an Approve card. Once per thread;
    /// only for your own checkout, which is where it's written.
    func offerPlaybookSetup(for bot: Bot, purpose: String, store: BotStore) async {
        let thread = store.conversation(for: .bot(bot.id))
        if (thread.messages ?? []).contains(where: { if case .setUpPlaybook? = $0.action { true } else { false } }) { return }
        let folder = checkoutFolder.map { $0(bot) } ?? bot.folderBookmark.flatMap(RunCoordinator.resolve(bookmark:))
        guard let folder else { return }
        let files = (checkoutReader ?? PreviewSetup.readCheckout)(folder)
        guard !files.files.contains(PlaybookSetup.path) else { return }
        var setup = PlaybookSetup.general(name: bot.name, purpose: purpose, folderName: bot.folderName ?? folder.lastPathComponent)
        let readme = readmeReader.map { $0(folder) } ?? Self.readme(in: folder)
        let draft = if let playbookDrafter { await playbookDrafter(bot.name, purpose, readme) }
            else { await defaultPlaybookDraft(bot.name, purpose, readme) }
        if let draft {
            setup = setup.withDraft(persona: draft.persona, conventions: draft.conventions)
        }
        store.append(.assistant, setup.drafted
            ? String(localized: "This project has no PLAYBOOK.md, so I'm using general skills. Here's one for it; the persona and conventions are drafted on this device from your README, so check them, then Approve to write it into your checkout.")
            : String(localized: "This project has no PLAYBOOK.md, so I'm using general skills. Here's one for it to edit; Approve writes it into your checkout."), to: thread)
        store.proposeAction(.setUpPlaybook(setup), in: .bot(bot.id))
    }

    /// The checkout's README, read through its bookmark (up to 64 KB).
    nonisolated static func readme(in folder: URL) -> String? {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        for name in ["README.md", "Readme.md", "readme.md", "README"] {
            let file = folder.appendingPathComponent(name)
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 else { continue }
            if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        }
        return nil
    }

    /// The on-device model's draft of a persona and the project's
    /// conventions, from its README; nil when the model isn't available or
    /// there's no README. Prose only: the file's structure is fixed in code.
    private func defaultPlaybookDraft(_ name: String, _ purpose: String, _ readme: String?) async -> (persona: String, conventions: String)? {
        #if canImport(FoundationModels)
        guard useOnDeviceModel, onDeviceUnavailableReason == nil, let readme, !readme.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: "You write two short parts of a playbook for a coding assistant that looks after one software project, using only facts in the project's README. Never invent a framework, folder or command the README doesn't name.")
        let prompt = "Project name: \(name)\nWhat it is: \(purpose)\n\nREADME:\n\(readme.prefix(6000))"
        guard let draft = try? await session.respond(to: prompt, generating: DraftedPlaybook.self).content else { return nil }
        return (draft.persona, draft.conventions)
        #else
        return nil
        #endif
    }

    /// The project has no preview recipe: offer one worked out from its own
    /// files (an Approve card), or say a clone needs your checkout. Once per
    /// thread.
    func offerPreviewSetup(for bot: Bot, store: BotStore) {
        let thread = store.conversation(for: .bot(bot.id))
        let messages = thread.messages ?? []
        if messages.contains(where: { if case .setUpPreview? = $0.action { true } else { false } }) { return }
        let folder = checkoutFolder.map { $0(bot) } ?? bot.folderBookmark.flatMap(RunCoordinator.resolve(bookmark:))
        guard let folder else {
            let note = String(localized: "There's no preview yet: darkmux runs a preview only from your own checkout of the repo, and this one is a clone. Add your checkout with Add folder in this bot's info.")
            if !messages.contains(where: { $0.content == note }) { store.append(.assistant, note, to: thread) }
            return
        }
        let files = (checkoutReader ?? PreviewSetup.readCheckout)(folder)
        let draft = ProjectSetupDetector.detect(packageJSON: files.packageJSON, files: files.files)
        guard !draft.isEmpty else {
            let note = String(localized: "There's no preview yet, and I couldn't work out how to run this project from its files (no package.json with a dev, start or serve script). Add .darkmux/preview.json to your checkout to get one.")
            if !messages.contains(where: { $0.content == note }) { store.append(.assistant, note, to: thread) }
            return
        }
        store.append(.assistant, String(localized: "This project has no preview recipe yet. Here's one worked out from its own files: check each value, then Approve to write it into your checkout."), to: thread)
        store.proposeAction(.setUpPreview(PreviewSetup(draft, folderName: bot.folderName ?? folder.lastPathComponent)), in: .bot(bot.id))
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
