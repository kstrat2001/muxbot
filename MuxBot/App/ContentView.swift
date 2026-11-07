import SwiftUI

/// macOS and iPad: a sidebar of Mux Bot, each bot and Activity, with the
/// selected thread beside it. iPhone: two tabs, Bots (Home grid, then
/// threads) and Activity.
struct ContentView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var wantsSidebar: Bool { sizeClass == .regular }
    #else
    private let wantsSidebar = true
    #endif

    var body: some View {
        @Bindable var router = router
        Group {
            if wantsSidebar { split } else { tabs }
        }
        .onAppear { router.usesSidebar = wantsSidebar }
        .onChange(of: wantsSidebar) { router.usesSidebar = wantsSidebar }
        #if DEBUG
        .task { openThreadFromLaunchArgument() }
        #endif
        .sheet(isPresented: $router.showNewBot) {
            NavigationStack { NewBotView() }
        }
        .sheet(isPresented: $router.showPairing) {
            NavigationStack { FleetPairingView() }
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
        router.usesSidebar = wantsSidebar
        if name == LeadBot.name { router.navigate(to: .lead); return }
        if name == "Activity" { router.tab = .activity; router.sidebar = .activity; return }
        if let bot = BotStore(context: context).allBots().first(where: { $0.name == name }) {
            router.navigate(to: .bot(bot.id))
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

    private var tabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.tab) {
            Tab("Bots", systemImage: "bubble.left.and.bubble.right", value: AppTab.bots) {
                NavigationStack(path: $router.path) {
                    HomeView()
                        .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
                }
            }
            Tab("Activity", systemImage: "waveform.path.ecg", value: AppTab.activity) {
                NavigationStack { ActivityView() }
            }
        }
    }

    private var split: some View {
        @Bindable var router = router
        let columns = Binding<NavigationSplitViewVisibility>(
            get: { router.previewFullScreen && router.showPreview ? .detailOnly : .all },
            set: { _ in })
        return NavigationSplitView(columnVisibility: columns) {
            BotSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            NavigationStack(path: $router.path) {
                Group {
                    switch router.sidebar {
                    case .activity?: ActivityView()
                    case let .bot(id)?: BotThreadView(context: .bot(id)).id(id)
                    case .lead?, nil: BotThreadView(context: .lead)
                    }
                }
                .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
            }
        }
    }
}
