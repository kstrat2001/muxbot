import SwiftUI

/// Where the user is. Radio reads it so work starts where the user is looking.
enum RadioContext: Equatable {
    case home
    case role(UUID)

    var roleId: UUID? {
        if case let .role(id) = self { id } else { nil }
    }
}

@MainActor @Observable
final class AppRouter {
    var path: [Route] = []
    var showNewRole = false

    /// Follows navigation: a role's chat on top means Radio talks about that role.
    var context: RadioContext {
        switch path.last {
        case let .roleChat(id): .role(id)
        case nil: .home
        }
    }

    func navigate(to route: Route) {
        path.append(route)
    }

    func popToRoot() {
        path = []
    }
}
