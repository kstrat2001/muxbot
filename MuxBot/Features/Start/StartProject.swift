import Foundation

/// Starting a project from a use case: a new bot made from the template's
/// playbook (persona, look, skills), then darkmux sets up its workspace on
/// this Mac from the template at its pinned ref, local only (no remote)
/// until it goes to GitHub. Reads only the entry and its playbook: no use
/// case has code of its own.
@MainActor
enum StartProject {
    struct Answers: Equatable {
        var name: String
        var purpose: String = ""
        var style: String = ""
    }

    /// Makes the bot and asks darkmux for its workspace. The bot exists even
    /// if the workspace fails; its thread says why and it can be retried.
    @discardableResult
    static func start(_ entry: TemplateEntry, playbook: Playbook, answers: Answers,
                      store: BotStore, runs: RunCoordinator) async -> Bot {
        let name = answers.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bot = store.add(name: name, instructions: instructions(playbook, answers: answers, name: name),
                            systemImage: playbook.icon)
        let suggested = BotLook.suggested(for: name)
        bot.look = BotLook(animal: playbook.animal ?? suggested.animal,
                           bodyHex: playbook.bodyHex ?? suggested.bodyHex,
                           eyeHex: playbook.eyeHex ?? suggested.eyeHex)
        bot.useCaseId = entry.id
        bot.skills = playbook.skills
        store.save()
        await runs.setUpWorkCopy(for: bot, store: store, template: entry)
        return bot
    }

    /// The persona, then what you said it's for and how it should feel.
    static func instructions(_ playbook: Playbook, answers: Answers, name: String) -> String {
        var parts = [playbook.persona(for: name)]
        let purpose = answers.purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = answers.style.trimmingCharacters(in: .whitespacesAndNewlines)
        if !purpose.isEmpty { parts.append("It's for: \(purpose)") }
        if !style.isEmpty { parts.append("How it should feel: \(style)") }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
