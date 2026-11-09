import Foundation

/// A card Mux Bot posts in its thread (`MessageKind.guideCard`). Saved as
/// JSON in the message's `actionJSON`; the message's content is a plain
/// summary (what Home's lead card shows). Each card shows live state when
/// drawn: the checklist re-checks, a setting shows its current value.
enum GuideCard: Codable, Equatable, Sendable {
    /// The live setup checklist.
    case setup
    /// Make your first bot: New bot, or paste a repo link.
    case firstBot
    /// A setting's live switch.
    case setting(GuideSettingID)
    /// An answer from the help, citing its articles. `onDevice`: written by
    /// the on-device model from them; otherwise the article's own words.
    case answer(text: String, articles: [String], onDevice: Bool)
    /// In a bot's thread: you reported something cut off, and the page fits
    /// at every width measured; the note offers to reload the preview.
    case pageFits(text: String)
}

extension ChatMessage {
    var guideCard: GuideCard? {
        guard kind == .guideCard else { return nil }
        return actionJSON.flatMap { try? JSONDecoder().decode(GuideCard.self, from: Data($0.utf8)) }
    }
}

extension BotStore {
    @discardableResult
    func postGuideCard(_ card: GuideCard, summary: String, in chat: ChatContext = .lead) -> ChatMessage {
        let message = append(.assistant, summary, kind: .guideCard, to: conversation(for: chat))
        message.actionJSON = (try? JSONEncoder().encode(card)).flatMap { String(data: $0, encoding: .utf8) }
        save()
        return message
    }
}
