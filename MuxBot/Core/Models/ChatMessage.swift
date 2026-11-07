import Foundation
import SwiftData

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

@Model
final class ChatMessage {
    var id: UUID = UUID()
    var role: ChatRole = ChatRole.user
    var content: String = ""
    var timestamp: Date = Date()
    var conversation: ChatConversation?

    init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}
