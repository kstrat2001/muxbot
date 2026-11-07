import Foundation
import SwiftData

/// A chat thread. `roleId == nil` is the Radio conversation; otherwise the
/// thread belongs to one role in the app's role store.
@Model
final class ChatConversation {
    var id: UUID = UUID()
    var title: String = ""
    var roleId: UUID?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage]? = []

    init(title: String = "", roleId: UUID? = nil) {
        self.title = title
        self.roleId = roleId
    }
}
