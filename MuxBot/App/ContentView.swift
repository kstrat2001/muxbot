import SwiftUI

/// Two tabs: Bots, where all work starts in conversation, and Work, a
/// read-only view of what the fleet is doing. Sidebar on macOS and iPad.
struct ContentView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Bots", systemImage: "bubble.left.and.bubble.right", value: AppTab.bots) {
                NavigationStack(path: $router.path) {
                    HomeView()
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                }
            }
            Tab("Work", systemImage: "checklist", value: AppTab.work) {
                NavigationStack { WorkView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if DEBUG
        .task { openThreadFromLaunchArgument() }
        #endif
        .sheet(isPresented: $router.showNewBot) {
            NavigationStack { NewBotView() }
        }
    }

    #if DEBUG
    /// `-openBot <name>` (or `-openBot "Mux Bot"`) opens that thread on
    /// launch, for screenshot checks. Debug builds only.
    private func openThreadFromLaunchArgument() {
        #if os(macOS)
        if UserDefaults.standard.bool(forKey: "snapshot") { Task { await snapshotWindow() } }
        #endif
        if UserDefaults.standard.bool(forKey: "showPreview") { router.showPreview = true }
        guard let name = UserDefaults.standard.string(forKey: "openBot") else { return }
        if name == LeadBot.name { router.path = [.lead]; return }
        if let bot = BotStore(context: context).allBots().first(where: { $0.name == name }) {
            router.path = [.bot(bot.id)]
        }
    }

    #if os(macOS)
    /// `-snapshot YES` writes the window to the app's temp folder after a
    /// moment, for layout checks without screen-recording permission.
    private func snapshotWindow() async {
        try? await Task.sleep(for: .seconds(3))
        guard let view = NSApp.windows.first(where: \.isVisible)?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muxbot-snapshot.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
    #endif
}
