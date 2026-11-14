import Foundation

/// "help me", "I'm stuck", "what can I do?" in a bot's thread: where the
/// project stands and up to three next steps, worked out by rules from the
/// app's own state, never by the model. Each step is a message the bot
/// gets as if you typed it, so nothing starts without its usual card.
enum NextSteps {
    struct Step: Codable, Equatable, Sendable {
        var title: String
        var systemImage: String
        /// Sent as your message when tapped.
        var message: String
    }

    static let maxSteps = 3

    private static let phrases: Set<String> = [
        "help", "help me", "help please", "please help", "i need help", "i'm stuck", "im stuck", "i am stuck", "stuck",
        "what can i do", "what can you do", "what do i do", "what should i do", "what now", "now what",
        "where do i start", "where should i start", "how do i start", "i don't know what to do", "i dont know what to do",
        "what do you do", "what can we do", "ideas", "any ideas", "give me ideas", "?",
    ]

    /// Whether the message only asks for help with what to do.
    static func matches(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        if lower == "?" { return true }
        let bare = lower.hasSuffix("?") ? String(lower.dropLast()).trimmingCharacters(in: .whitespaces) : lower
        return phrases.contains(bare)
    }

    static var closing: String { String(localized: "Or tell me in your own words what you want, or ask me how something works.") }

    /// Where the project stands, and what to do next.
    @MainActor
    static func read(_ bot: Bot, runs: RunCoordinator, store: BotStore) -> (status: String, steps: [Step]) {
        let all = (bot.runs ?? []).sorted { $0.createdAt < $1.createdAt }
        #if !os(macOS)
        let onMac = false
        #else
        let onMac = true
        #endif
        if all.contains(where: { $0.phase == .proposed }) {
            return (String(localized: "A change is waiting above. Tap Approve on its card to start it, or Cancel if it's not what you want."), [])
        }
        if let running = all.first(where: { $0.phase.isActive }) {
            let steps = runs.canPreview(bot) ? [step(.openPreview)] : []
            return (String(localized: "The crew is working on “\(running.task)”. I'll post the result here when it's done."), steps)
        }
        var steps: [Step] = []
        let status: String
        if let last = all.last(where: { $0.startedAt != nil }) {
            switch last.phase {
            case .failed, .canceled:
                status = String(localized: "Your last change didn't finish. Its card above says why, and you can try it again from there.")
            case .result where last.needsYou:
                status = String(localized: "The crew has a question for you above. Answer it there.")
            default:
                status = last.keptCommit != nil
                    ? String(localized: "Your last change is saved. Reply to change it, or say “undo” to take it back.")
                    : String(localized: "Nothing new is waiting on you.")
            }
        } else {
            status = String(localized: "Nothing's been changed yet. Pick one of these to start.")
        }
        if onMac, AppAction.startReview.unavailable(for: bot, runs: runs, store: store) == nil {
            steps.append(step(.startReview))
        }
        if runs.canPreview(bot), runs.livePreviews[bot.id] == nil { steps.append(step(.openPreview)) }
        steps += bot.skills.map { Step(title: $0.name, systemImage: "wand.and.stars", message: $0.name) }
        if runs.canPreview(bot) { steps.append(step(.pickMode)) }
        return (status, Array(steps.prefix(maxSteps)))
    }

    private static func step(_ action: AppAction) -> Step {
        switch action {
        case .startReview: Step(title: String(localized: "Review my changes"), systemImage: "checkmark.bubble", message: "review my changes")
        case .pickMode: Step(title: String(localized: "Point at something"), systemImage: "scope", message: "point at something")
        default: Step(title: String(localized: "Show the preview"), systemImage: "play.rectangle", message: "show the preview")
        }
    }
}
