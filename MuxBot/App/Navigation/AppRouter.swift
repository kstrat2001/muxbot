import SwiftUI

@MainActor @Observable
final class AppRouter {
    var path = NavigationPath()
    var showNewRole = false
    /// Set to move focus into the Radio dock on Home.
    var focusRadio = false

    func navigate(to route: Route) {
        path.append(route)
    }

    /// Radio is the only way to start work, so every "start work" path lands
    /// on Home with the Radio dock focused.
    func openRadio() {
        path = NavigationPath()
        focusRadio = true
    }

    func popToRoot() {
        path = NavigationPath()
    }
}
