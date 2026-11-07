import SwiftUI

struct ContentView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
        }
        .safeAreaInset(edge: .bottom) { RadioDock() }
        .sheet(isPresented: $router.showNewRole) {
            NavigationStack { NewRoleView() }
        }
    }
}
