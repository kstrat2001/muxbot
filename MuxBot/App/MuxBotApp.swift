import SwiftUI
import SwiftData

@main
struct MuxBotApp: App {
    @State private var router = AppRouter()
    @State private var brain = BotBrain()
    @State private var preview = PreviewController()
    @State private var connection = FleetConnection()
    @State private var notifications = NotificationService()
    @State private var store = StoreLoader()
    @State private var github = GitHubAuth()
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        // One main window: a second one would share the router and the one
        // preview page, and follow every run twice. The menu bar items bring
        // this window forward (`openWindow(id: "main")`).
        Window(LeadBot.name, id: "main") { main }
            .commands { MuxBotCommands(router: router) }
        #else
        WindowGroup(id: "main") { main }
            .commands { MuxBotCommands(router: router) }
        #endif

        #if os(macOS)
        Settings {
            // The store too: pairing here counts the real bots, so it never
            // moves the main window to Start.
            Group {
                if let container = store.container {
                    SettingsView().modelContainer(container)
                } else {
                    SettingsView()
                }
            }
            .environment(router)
            .environment(brain)
            .environment(connection)
            .environment(notifications)
            .environment(github)
        }

        MenuBarExtra {
            if let container = store.container {
                MenuBarRuns().environment(router).modelContainer(container)
            }
        } label: {
            if let container = store.container {
                MenuBarLabel().environment(notifications).modelContainer(container)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
            }
        }
        #endif
    }

    /// The main window's content: the app, or why its data couldn't open.
    @ViewBuilder private var main: some View {
        if let container = store.container {
            ContentView()
                .environment(router)
                .environment(brain)
                .environment(preview)
                .environment(connection)
                .environment(notifications)
                .environment(github)
                .modelContainer(container)
                .task {
                    brain.pageInspector = preview
                    if brain.layoutProbe == nil { brain.layoutProbe = WebLayoutProbe() }
                    brain.connection = connection
                    brain.notifier = notifications
                    brain.runs.githubToken = { [github] in github.token }
                    GitHubSession.refresh = { [github] in await github.refresh() }
                    brain.runs.adoptLegacyRuns(store: BotStore(context: container.mainContext))
                    brain.runs.resumeFollowing(store: BotStore(context: container.mainContext))
                    #if os(macOS)
                    appDelegate.runs = brain.runs
                    #endif
                }
        } else {
            StoreRecoveryView(loader: store)
        }
    }
}

#if os(macOS)
/// Quitting stops the previews this app started, so no dev server outlives it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var runs: RunCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runs else { return .terminateNow }
        Task { @MainActor in
            await runs.stopAllPreviews()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif

/// Opens the store (migrating it if needed). If it can't, the app shows
/// why and offers to start fresh, with the old files kept, instead of
/// crashing.
@MainActor @Observable
final class StoreLoader {
    private(set) var container: ModelContainer?
    private(set) var error: String?
    private(set) var movedAside: [URL] = []

    init() { load() }

    /// Tests run inside the app; they must never open (or migrate) the
    /// real store.
    static var isTestHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
    /// UI tests launch the app with `-uiTesting`: an in-memory store with one
    /// bot whose preview is a blank page, never the real store.
    static var isUITesting: Bool { ProcessInfo.processInfo.arguments.contains("-uiTesting") || isUITestingEmpty }
    /// `-uiTestingEmpty`: the same in-memory store with no bots (first launch).
    static var isUITestingEmpty: Bool { ProcessInfo.processInfo.arguments.contains("-uiTestingEmpty") }

    func load() {
        do {
            let inMemory = Self.isTestHost || Self.isUITesting
            let opened = inMemory ? try SharedModelContainer.inMemory() : try SharedModelContainer.create()
            if Self.isUITesting, !Self.isUITestingEmpty {
                let store = BotStore(context: opened.mainContext)
                let bot = store.addExample()
                store.addResource(.previewURL, "about:blank", to: bot)
            }
            BotStore(context: opened.mainContext).migrateWorkCopies(machine: FleetConnection.machineName)
            container = opened
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Moves the store aside (kept, renamed) and opens a new, empty one.
    func startFresh() {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        do {
            movedAside = try SharedModelContainer.moveAside(storeURL: SharedModelContainer.storeURL, stamp: stamp)
            load()
        } catch {
            self.error = "Couldn't move the old data aside: \(error.localizedDescription)"
        }
    }
}

struct StoreRecoveryView: View {
    let loader: StoreLoader

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 44)).foregroundStyle(Color.brandOrange)
            Text("Mux Bot couldn't open its data").font(AppFont.title2())
            Text(loader.error ?? "").font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center).textSelection(.enabled)
            HStack {
                Button("Try again", systemImage: "arrow.clockwise") { loader.load() }
                Button("Start fresh", systemImage: "sparkles") { loader.startFresh() }
                    .buttonStyle(.borderedProminent)
            }
            Text("Start fresh keeps your old data: the files are renamed, not deleted, next to the new store.")
                .font(AppFont.caption()).foregroundStyle(Color.secondaryText).multilineTextAlignment(.center)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
