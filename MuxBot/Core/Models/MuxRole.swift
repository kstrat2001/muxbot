import Foundation
import SwiftData

/// Where a role stands. Drives the Home grouping.
enum RoleState: String, Codable, CaseIterable, Sendable {
    case needsYou, working, ready

    var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .ready: "Ready"
        }
    }
}

/// A role in the app's own role store. Named `MuxRole` to avoid clashing
/// with `ChatRole`. Persisted with SwiftData; not a mirror of darkmux config.
@Model
final class MuxRole {
    var id: UUID = UUID()
    var name: String = ""
    /// What this role does, in plain words. Radio routes work by it.
    var instructions: String = ""
    /// The local model this role should run on. Empty means the default.
    var modelName: String = ""
    var systemImage: String = "sparkles"
    @Attribute(.externalStorage) var avatarImageData: Data?
    var state: RoleState = RoleState.ready
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \RoleTask.role)
    var tasks: [RoleTask]? = []

    init(name: String, instructions: String, modelName: String = "", systemImage: String = "sparkles", state: RoleState = RoleState.ready) {
        self.name = name
        self.instructions = instructions
        self.modelName = modelName
        self.systemImage = systemImage
        self.state = state
    }

    /// The task this role is on, newest first.
    var currentTask: RoleTask? {
        (tasks ?? []).max { $0.createdAt < $1.createdAt }
    }
}

/// A piece of work Radio gave a role. Local only until the fleet is wired.
@Model
final class RoleTask {
    var id: UUID = UUID()
    var title: String = ""
    var why: String = ""
    var createdAt: Date = Date()
    var role: MuxRole?

    init(title: String, why: String) {
        self.title = title
        self.why = why
    }
}
