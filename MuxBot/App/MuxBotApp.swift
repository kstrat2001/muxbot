import SwiftUI
import SwiftData

@main
struct MuxBotApp: App {
    @State private var router = AppRouter()
    @State private var brain = BotBrain()
    @State private var preview = PreviewController()
    @State private var connection = FleetConnection()
    @State private var notifications = NotificationService()

    private let container: ModelContainer

    init() {
        do {
            container = try SharedModelContainer.create()
        } catch {
            fatalError("Could not create the model container: \(error)")
        }
        BotStore(context: container.mainContext).seedIfEmpty()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(router)
                .environment(brain)
                .environment(preview)
                .environment(connection)
                .environment(notifications)
                .task {
                    brain.pageInspector = preview
                    brain.connection = connection
                    brain.resumeFollowing(store: BotStore(context: container.mainContext))
                }
        }
        .modelContainer(container)
    }
}
