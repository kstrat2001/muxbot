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

    var body: some Scene {
        WindowGroup {
            if let container = store.container {
                ContentView()
                    .environment(router)
                    .environment(brain)
                    .environment(preview)
                    .environment(connection)
                    .environment(notifications)
                    .modelContainer(container)
                    .task {
                        brain.pageInspector = preview
                        brain.connection = connection
                        brain.resumeFollowing(store: BotStore(context: container.mainContext))
                    }
            } else {
                StoreRecoveryView(loader: store)
            }
        }
    }
}

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

    func load() {
        do {
            let opened = Self.isTestHost ? try SharedModelContainer.inMemory() : try SharedModelContainer.create()
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
            Text(loader.error ?? "").font(AppFont.footnote()).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
            HStack {
                Button("Try again", systemImage: "arrow.clockwise") { loader.load() }
                Button("Start fresh", systemImage: "sparkles") { loader.startFresh() }
                    .buttonStyle(.borderedProminent)
            }
            Text("Start fresh keeps your old data: the files are renamed, not deleted, next to the new store.")
                .font(AppFont.caption()).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
