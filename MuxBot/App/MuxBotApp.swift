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
                    brain.runs.onPreviewStopped = { [preview] in preview.forget($0) }
                    if brain.layoutProbe == nil { brain.layoutProbe = WebLayoutProbe() }
                    brain.connection = connection
                    brain.notifier = notifications
                    brain.runs.githubToken = { [github] in github.token }
                    GitHubSession.refresh = { [github] in await github.renewal() }
                    // A sign-in kept from before is checked (renewed if it
                    // expired, else you're told to sign in again).
                    if github.token != nil { await github.loadUser() }
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
/// One Mux Bot at a time on a Mac. macOS can start a different copy of the
/// app (another build with the same bundle id) for a notification click
/// while one is already running; that copy brings the running one forward
/// and quits, so the store is never opened twice.
enum SingleInstance {
    /// The pid of another running Mux Bot, if any (never this process).
    static func other(among pids: [pid_t], me: pid_t) -> pid_t? {
        pids.first { $0 != me }
    }

    @MainActor static func handOffIfAnotherIsRunning() {
        // The unit tests' host is this app: it must start even while the
        // real app runs.
        guard !TestIsolation.isTesting, let id = Bundle.main.bundleIdentifier else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated }
        guard let pid = other(among: running.map(\.processIdentifier), me: ProcessInfo.processInfo.processIdentifier),
              let app = running.first(where: { $0.processIdentifier == pid }) else { return }
        app.activate()
        exit(0)
    }
}
#endif

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
/// why instead of crashing: a store saved by a newer Mux Bot says to open
/// that one (never Start fresh, which would hide the data from it), and any
/// other failure offers Try again, with Start fresh (old files kept)
/// behind a confirmation.
@MainActor @Observable
final class StoreLoader {
    private(set) var container: ModelContainer?
    private(set) var error: String?
    /// The store was saved by a newer Mux Bot than this one.
    private(set) var storeIsNewer = false
    private(set) var movedAside: [URL] = []

    init() {
        #if os(macOS)
        // Before the store opens: a second copy (another build with the same
        // bundle id, started by a notification or the Dock) never opens it.
        SingleInstance.handOffIfAnotherIsRunning()
        #endif
        load()
    }

    /// Tests run inside the app; they must never open (or migrate) the
    /// real store.
    static var isTestHost: Bool { TestIsolation.isUnitTesting }
    /// UI tests launch the app with `-uiTesting`: an in-memory store with one
    /// bot whose preview is a blank page, never the real store.
    static var isUITesting: Bool { TestIsolation.isUITesting }
    /// `-uiTestingEmpty`: the same in-memory store with no bots (first launch).
    static var isUITestingEmpty: Bool { ProcessInfo.processInfo.arguments.contains("-uiTestingEmpty") }

    func load() {
        do {
            // One flag (`TestIsolation`) for the store and everything else
            // a test must not share with the real app.
            let inMemory = TestIsolation.isTesting
            let opened = inMemory ? try SharedModelContainer.inMemory() : try SharedModelContainer.create()
            if Self.isUITesting, !Self.isUITestingEmpty {
                let store = BotStore(context: opened.mainContext)
                let bot = store.addExample()
                store.addResource(.previewURL, "about:blank", to: bot)
            }
            BotStore(context: opened.mainContext).migrateWorkCopies(machine: FleetConnection.machineName)
            container = opened
            error = nil
            storeIsNewer = false
        } catch {
            self.error = String(describing: error)
            storeIsNewer = !TestIsolation.isTesting && SharedModelContainer.isFromNewerApp(storeURL: SharedModelContainer.storeURL)
        }
    }

    /// Moves the store aside (kept, renamed) and opens a new, empty one.
    /// Never for a store a newer Mux Bot saved: that one reads it fine.
    func startFresh() {
        guard !storeIsNewer else { return }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        do {
            movedAside = try SharedModelContainer.moveAside(storeURL: SharedModelContainer.storeURL, stamp: stamp)
            load()
        } catch {
            self.error = "Couldn't move the old data aside: \(error)"
        }
    }

    func quit() {
        #if os(macOS)
        NSApplication.shared.terminate(nil)
        #endif
    }
}

struct StoreRecoveryView: View {
    let loader: StoreLoader
    @State private var confirmingStartFresh = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 44)).foregroundStyle(Color.brandOrange)
            if loader.storeIsNewer { newer } else { failed }
            if let error = loader.error { TechnicalDetails(text: error) }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// An older copy of the app: the data is fine, open the newer one.
    @ViewBuilder private var newer: some View {
        Text("This Mux Bot is older than your data").font(AppFont.title2()).multilineTextAlignment(.center)
        #if os(macOS)
        Text("Your bots and threads are safe. A newer Mux Bot saved them, and this copy can't read them. Quit this copy and open the newest Mux Bot.")
            .font(AppFont.body()).foregroundStyle(Color.secondaryText).multilineTextAlignment(.center)
        Button("Quit", systemImage: "xmark.circle") { loader.quit() }
            .buttonStyle(.borderedProminent).tint(Color.brandGreen)
        #else
        Text("Your bots and threads are safe. A newer Mux Bot saved them, and this copy can't read them. Update Mux Bot to open them.")
            .font(AppFont.body()).foregroundStyle(Color.secondaryText).multilineTextAlignment(.center)
        #endif
    }

    /// Any other failure: try again first; starting fresh is a confirmed,
    /// secondary choice.
    @ViewBuilder private var failed: some View {
        Text("Mux Bot couldn't open its data").font(AppFont.title2()).multilineTextAlignment(.center)
        Text("Your bots and threads are still on this device. Try again, or quit Mux Bot and open it again.")
            .font(AppFont.body()).foregroundStyle(Color.secondaryText).multilineTextAlignment(.center)
        HStack {
            Button("Try again", systemImage: "arrow.clockwise") { loader.load() }
                .buttonStyle(.borderedProminent).tint(Color.brandGreen)
            #if os(macOS)
            Button("Quit") { loader.quit() }
            #endif
        }
        Button("Start fresh…") { confirmingStartFresh = true }
            .buttonStyle(.borderless).font(AppFont.footnote())
            .confirmationDialog("Start fresh with no bots?", isPresented: $confirmingStartFresh) {
                Button("Start fresh") { loader.startFresh() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your old data is kept: its files are renamed, not deleted, next to the new store.")
            }
    }
}
