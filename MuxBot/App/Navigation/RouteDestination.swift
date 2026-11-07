import SwiftUI

struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .roleChat(let id):
            RoleChatView(roleId: id)
        }
    }
}
