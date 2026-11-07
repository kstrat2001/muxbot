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
}

@Model
final class ChatMessage {
    var id: UUID = UUID()
    var role: ChatRole = ChatRole.user
    var content: String = ""
    var timestamp: Date = Date()
    var kind: MessageKind = MessageKind.text
    var runId: UUID?
    var conversation: ChatConversation?

    init(role: ChatRole, content: String, kind: MessageKind = MessageKind.text, runId: UUID? = nil) {
        self.role = role
        self.content = content
        self.kind = kind
        self.runId = runId
    }
}
