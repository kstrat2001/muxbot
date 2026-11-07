import SwiftUI

/// Two tabs: Bots, where all work starts in conversation, and Work, a
/// read-only view of what the fleet is doing. Sidebar on macOS and iPad.
struct ContentView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Bots", systemImage: "bubble.left.and.bubble.right", value: AppTab.bots) {
                NavigationStack(path: $router.path) {
                    HomeView()
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                }
                .safeAreaInset(edge: .bottom) { BotBar() }
            }
            Tab("Work", systemImage: "checklist", value: AppTab.work) {
                NavigationStack { WorkView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: $router.showNewBot) {
            NavigationStack { NewBotView() }
        }
    }
}
