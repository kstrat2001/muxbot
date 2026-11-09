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

    static let dontKnow = String(localized: "I don't know that one: it isn't in Mux Bot's help. I can help you get set up, make your first bot, and answer questions about Mux Bot and darkmux.")

    func respond(_ route: GuideRoute, to text: String, store: BotStore, brain: BotBrain) async {
        let thread = store.conversation(for: .lead)
        switch route {
        case .setup:
            store.append(.assistant, String(localized: "Here's what Mux Bot needs. Each step ticks itself off once it's working."), to: thread)
            store.postGuideCard(.setup, summary: String(localized: "Setup check"))
        case let .firstBot(resource?):
            let draft = Self.draft(for: resource)
            store.append(.assistant, String(localized: "I can make \(draft.name) for that. Approve to add it."), to: thread)
            store.proposeAction(.createBot(draft), in: .lead)
        case .firstBot(nil):
            store.append(.assistant, String(localized: "A bot is a project you name. Paste its GitHub link here, or use New bot to add a folder from this Mac."), to: thread)
            store.postGuideCard(.firstBot, summary: String(localized: "Make your first bot"))
        case let .setting(id):
            await respondAboutSetting(id, text: text, store: store, brain: brain)
        case .help:
            await answer(text, store: store, brain: brain)
        }
    }

    /// A bot for a repo link or folder path, named after it.
    static func draft(for resource: String) -> BotDraft {
        let name = GitHubIssue.repoSlug(from: resource).map { String($0.split(separator: "/").last ?? "") }
            ?? URL(fileURLWithPath: (resource as NSString).expandingTildeInPath).lastPathComponent
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
        store.append(.assistant, [explanation?.text, lead].compactMap { $0 }.joined(separator: "\n\n"), to: thread)
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
