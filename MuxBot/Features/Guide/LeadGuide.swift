import Foundation
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Mux Bot's answers as a guide, in its own thread. It posts cards and
/// answers; it never starts work.
@MainActor
final class LeadGuide {
    var library = HelpLibrary.bundled
    private static let log = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "guide")

    static let dontKnow = String(localized: "I don't know that one: it isn't in Mux Bot's help. I can help you start a project, get set up, and answer questions about Mux Bot and darkmux.")

    /// The first thing Mux Bot says in his thread.
    nonisolated static let intro = String(localized: "Hi, I'm \(LeadBot.name). I can help you start a project, check your setup, change a setting, and answer questions about how Mux Bot and darkmux work. Try “start a project”.")
    /// His reply to anything the guide doesn't take: what he does, never an
    /// improvised answer.
    nonisolated static let menuText = String(localized: "I can help you start a project, check your setup, change a setting, or explain how something works. Pick one below, or tell me which.")

    func respond(_ route: GuideRoute, to text: String, store: BotStore, brain: BotBrain) async {
        let thread = store.conversation(for: .lead)
        switch route {
        case .setup:
            store.append(.assistant, String(localized: "Here's what Mux Bot needs. Each step ticks itself off once it's working."), to: thread)
            store.postGuideCard(.setup, summary: String(localized: "Setup check"))
        case let .firstBot(resource?):
            guard let draft = Self.draft(for: resource) else {
                // Folders come only from Add folder (a bookmark kept on this
                // Mac): a typed path would be saved in synced data.
                store.append(.assistant, String(localized: "For a folder on this Mac, choose New, then Work on a project I already have, and pick the folder, so Mux Bot can open it."), to: thread)
                store.postGuideCard(.firstBot, summary: String(localized: "Make your first bot"))
                return
            }
            store.append(.assistant, String(localized: "I can make \(draft.name) for that. Approve to add it."), to: thread)
            store.proposeAction(.createBot(draft), in: .lead)
        case .firstBot(nil):
            store.append(.assistant, String(localized: "A bot is a project you name. Paste its GitHub link here, or choose New, then Work on a project I already have, to add a folder from this Mac."), to: thread)
            store.postGuideCard(.firstBot, summary: String(localized: "Make your first bot"))
        case let .setting(id):
            await respondAboutSetting(id, text: text, store: store, brain: brain)
        case .settingsOverview:
            let paired = brain.runs.connection?.isPaired ?? false
            let shown = GuideSettings.all.filter { !$0.isReadOnly || ($0.isDarkmux && paired) }
            store.append(.assistant, String(localized: "Here are the settings I can change for you. Flip one and it changes right away; ask me about any of them."), to: thread)
            for setting in shown { store.postGuideCard(.setting(setting.id), summary: setting.title) }
        case .help:
            await answer(text, store: store, brain: brain)
        case let .startProject(template):
            let title = template.flatMap { id in TemplateRegistry.knownTemplates().first { $0.id == id }?.title }
            store.append(.assistant, title.map { String(localized: "Let's start: \($0).") }
                         ?? String(localized: "Let's start a project. Pick what you want to make."), to: thread)
            brain.openStart?(template)
        }
    }

    /// A bot for a repo link, named after it; nil for anything else (a
    /// folder goes through New bot's Add folder).
    static func draft(for resource: String) -> BotDraft? {
        guard let name = GitHubIssue.repoSlug(from: resource).map({ String($0.split(separator: "/").last ?? "") }) else { return nil }
        return BotDraft(name: name.isEmpty ? String(localized: "New bot") : name,
                        instructions: String(localized: "Works on \(resource)."), resource: resource)
    }

    private func respondAboutSetting(_ id: GuideSettingID, text: String, store: BotStore, brain: BotBrain) async {
        let setting = GuideSettings.setting(id)
        let thread = store.conversation(for: .lead)
        let hits = library.search(text, in: setting.article)
        let explanation = await answerText(for: text, from: hits.isEmpty ? library.search(setting.title, in: setting.article) : hits, brain: brain)
        if setting.isDarkmux && !(brain.runs.connection?.isPaired ?? false) {
            store.append(.assistant, [explanation?.text, String(localized: "That's set in darkmux on your Mac. Pair Mux Bot first and I can show its value here.")]
                .compactMap { $0 }.joined(separator: "\n\n"), to: thread)
            return
        }
        let lead = GuideSettings.isChangeRequest(text.lowercased()) && !setting.isReadOnly
            ? String(localized: "Here's the switch. Changing it changes the setting right away.")
            : setting.isDarkmux ? String(localized: "This one is changed in darkmux on your Mac; here's its value.") : nil
        if let reply = Self.settingReply(explanation: explanation?.text, lead: lead) { store.append(.assistant, reply, to: thread) }
        store.postGuideCard(.setting(id), summary: setting.title)
    }

    private func answer(_ question: String, store: BotStore, brain: BotBrain) async {
        let hits = library.search(question)
        guard let answer = await answerText(for: question, from: hits, brain: brain) else {
            store.append(.assistant, Self.dontKnow, to: store.conversation(for: .lead))
            return
        }
        store.postGuideCard(.answer(text: answer.text, articles: answer.articles, onDevice: answer.onDevice), summary: answer.text)
    }

    struct Answer { var text: String; var articles: [String]; var onDevice: Bool }

    /// The on-device model's answer from the matched help, or the help's own
    /// words without it; nil when the help doesn't cover the question.
    private func answerText(for question: String, from hits: [HelpLibrary.Hit], brain: BotBrain) async -> Answer? {
        guard let top = hits.first else { return nil }
        var articles: [String] = []
        for hit in hits where !articles.contains(hit.article.id) { articles.append(hit.article.id) }
        if brain.useOnDeviceModel, brain.onDeviceUnavailableReason == nil, let reply = await modelAnswer(question, from: hits) {
            return reply.lowercased().contains("i don't know") ? nil : Answer(text: reply, articles: articles, onDevice: true)
        }
        return Answer(text: top.text, articles: [top.article.id], onDevice: false)
    }

    private func modelAnswer(_ question: String, from hits: [HelpLibrary.Hit]) async -> String? {
        #if canImport(FoundationModels)
        let help = hits.map { "\($0.article.title), \($0.section):\n\($0.text)" }.joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: """
            You are \(LeadBot.name), the guide in the Mux Bot app. \(LeadBot.persona)
            Answer the question in one to three short sentences, using only the help text below. \
            Keep commands exactly as written. If the help text doesn't answer it, reply exactly: I don't know.

            Help text:
            \(help.prefix(2400))
            """)
        do {
            return try await session.respond(to: question).content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Self.log.error("Guide answer failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        #else
        return nil
        #endif
    }
}

extension LeadGuide {
    /// What Mux Bot says above a setting's card; nil when there's nothing to
    /// say (the card speaks for itself), never an empty bubble.
    static func settingReply(explanation: String?, lead: String?) -> String? {
        let parts = [explanation, lead].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
