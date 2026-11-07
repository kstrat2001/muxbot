import Foundation
import SwiftData

/// A chat thread. `roleId == nil` is the lead bot's conversation; otherwise the
/// thread belongs to one role in the app's role store.
@Model
final class ChatConversation {
    var id: UUID = UUID()
    var title: String = ""
    var roleId: UUID?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// When you last looked at this thread; newer bot messages are unread.
    var lastReadAt: Date?

    /// A bot (or the system) said something since you last looked.
    var hasUnread: Bool {
        let latest = (messages ?? []).filter { $0.role != .user }.map(\.timestamp).max()
        guard let latest else { return false }
        return latest > (lastReadAt ?? .distantPast)
    }

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage]? = []

    init(title: String = "", roleId: UUID? = nil) {
        self.title = title
        self.roleId = roleId
    }
}
