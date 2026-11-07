import SwiftUI

struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .lead: BotThreadView(context: .lead)
        case .bot(let id): BotThreadView(context: .bot(id))
        }
    }
}
