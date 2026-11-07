import SwiftUI

@MainActor @Observable
final class AppRouter {
    var path = NavigationPath()
    var showNewRole = false

    func navigate(to route: Route) {
        path.append(route)
    }

    /// Radio is the only way to start work, so every "start work" path lands here.
    func openRadio() {
        path = NavigationPath()
        path.append(Route.radio)
    }

    func popToRoot() {
        path = NavigationPath()
    }
}
