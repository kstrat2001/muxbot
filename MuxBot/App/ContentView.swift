import SwiftUI
import SwiftData

/// macOS and iPad: a sidebar of Mux Bot, each bot and Activity, with the
/// selected thread beside it. iPhone: two tabs, Bots (Home grid, then
/// threads) and Activity.
struct ContentView: View {
    @Environment(AppRouter.self) private var router
    @Environment(FleetConnection.self) private var connection
    @Environment(BotBrain.self) private var brain
    @Environment(\.modelContext) private var context
    @Environment(NotificationService.self) private var notifications
    @Query private var runs: [BotRun]
    @Query private var bots: [Bot]

    /// Runs waiting on a decision: the app badge.
    private var waitingCount: Int { RunNotice.badgeCount(runs) }

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
        .onAppear {
            router.usesSidebar = wantsSidebar
            router.openOnStart(botCount: bots.count)
            // darkmux forgot this app (401): show pairing, which says why.
            let router = router
            connection.onRevoked = { router.showPairing = true }
            // "new project" in Mux Bot's thread opens Start (or a template's form).
            brain.openStart = { template in
                router.startTemplateId = template
                router.showStartProject = true
            }
            brain.openBot = { router.navigate(to: .bot($0)) }
        }
        .onChange(of: wantsSidebar) { router.usesSidebar = wantsSidebar }
        // Runs an earlier build kept become committed results (Open PR).
        .task {
            BotStore(context: context).migrateKeptRuns()
            // Threads two devices each made merge into one.
            BotStore(context: context).mergeDuplicateThreads()
        }
        // A bot deleted (here or on another device): its thread is left.
        .onChange(of: bots.map(\.id)) { router.botsChanged(existing: Set(bots.map(\.id))) }
        #if DEBUG
        .task { openThreadFromLaunchArgument() }
        #endif
        .sheet(isPresented: $router.showNewBot) {
            NavigationStack { NewBotView() }
                #if os(macOS)
                // Wide enough for the five state pills and a row of colors.
                .frame(minWidth: 560, idealWidth: 600, minHeight: 640, idealHeight: 720)
                #endif
        }
        .sheet(isPresented: $router.showStartProject) {
            NavigationStack { StartProjectView() }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 460)
                #endif
        }
        .sheet(isPresented: $router.showPairing) {
            NavigationStack { FleetPairingView() }
        }
        .sheet(isPresented: $router.showSearch) { SearchView() }
        // "open card" links in chat (muxbot://run/<id>) jump to that run's card.
        .environment(\.openURL, OpenURLAction { url in
            guard let id = RunLink.runId(from: url) else { return .systemAction }
            if let run = BotStore(context: context).run(id: id) { router.open(run) }
            return .handled
        })
        #if os(iOS)
        // On the Mac the menu bar item keeps the Dock badge (it lives while
        // the window is closed).
        .onChange(of: waitingCount, initial: true) { notifications.setBadge(waitingCount) }
        #endif
    }

    #if DEBUG
    /// `-openBot <name>` (or `-openBot "Mux Bot"`) opens that thread on
    /// launch, for screenshot checks. Debug builds only.
    private func openThreadFromLaunchArgument() {
        #if os(macOS)
        if UserDefaults.standard.bool(forKey: "snapshot") { Task { await snapshotWindow() } }
        #endif
        if UserDefaults.standard.bool(forKey: "showPreview") { router.showPreview = true }
        // `-showNewBot YES`, `-startTemplate <id>`: open those sheets, for
        // layout checks.
        if UserDefaults.standard.bool(forKey: "showNewBot") { router.showNewBot = true }
        if UserDefaults.standard.string(forKey: "startTemplate") != nil { router.showStartProject = true }
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
        // Every visible window, sheets included: muxbot-snapshot-<n>.png.
        for (n, window) in NSApp.windows.filter(\.isVisible).enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muxbot-snapshot-\(n).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
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
        // Full-window preview hides the sidebar; otherwise the toggle is yours.
        let fullWindow = router.previewFullScreen && router.showPreview
        let columns = Binding<NavigationSplitViewVisibility>(
            get: { fullWindow ? .detailOnly : router.columnVisibility },
            set: { if !fullWindow { router.columnVisibility = $0 } })
        return NavigationSplitView(columnVisibility: columns) {
            BotSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            NavigationStack(path: $router.path) {
                Group {
                    switch router.sidebar {
                    case .activity?: ActivityView()
                    case let .bot(id)?: BotThreadView(context: .bot(id)).id(id)
                    case .lead?: BotThreadView(context: .lead)
                    case nil:
                        // No bots yet: start with what you want to get done.
                        if bots.isEmpty { StartProjectView(inline: true) } else { BotThreadView(context: .lead) }
                    }
                }
                .navigationDestination(for: Route.self) { RouteDestination(route: $0) }
            }
        }
    }
}
