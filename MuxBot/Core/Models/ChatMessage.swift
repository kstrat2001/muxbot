import Foundation
import SwiftData

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

/// What a thread message shows. Run cards point at a `BotRun` and render
/// its stage: the dispatch proposal, the live run, the result, the PR.
enum MessageKind: String, Codable, Sendable {
    case text, dispatchCard, runCard, resultCard, prCard
    /// A drafted bug report; `content` holds the `BugDraft` as JSON.
    case bugCard
    /// An action other than a dispatch (hand-off, new bot, new resource)
    /// waiting for Approve; `actionJSON` holds the `BotAction`.
    case actionCard
}

/// Where an action card stands.
enum ActionState: String, Codable, Sendable {
    case waiting, approved, canceled
}

@Model
final class ChatMessage {
    var id: UUID = UUID()
    var role: ChatRole = ChatRole.user
    var content: String = ""
    var timestamp: Date = Date()
    var kind: MessageKind = MessageKind.text
    var runId: UUID?
    /// For your messages: how the bot read it (an `Intent` raw value).
    var intentRaw: String?
    /// For your messages: the preview element it was about, as JSON.
    var elementJSON: String?
    /// For action cards: the proposed `BotAction` as JSON, and its state.
    var actionJSON: String?
    var actionStateRaw: String?
    var conversation: ChatConversation?

    var action: BotAction? {
        actionJSON.flatMap { try? JSONDecoder().decode(BotAction.self, from: Data($0.utf8)) }
    }

    var actionState: ActionState {
        get { actionStateRaw.flatMap(ActionState.init(rawValue:)) ?? .waiting }
        set { actionStateRaw = newValue.rawValue }
    }

    init(role: ChatRole, content: String, kind: MessageKind = MessageKind.text, runId: UUID? = nil) {
        self.role = role
        self.content = content
        self.kind = kind
        self.runId = runId
    }
}
