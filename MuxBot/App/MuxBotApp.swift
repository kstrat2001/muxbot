import SwiftUI
import SwiftData

@main
struct MuxBotApp: App {
    @State private var router = AppRouter()
    @State private var brain = BotBrain()
    @State private var preview = PreviewController()
    @State private var notifications = NotificationService()

    private let container: ModelContainer

    init() {
        do {
            container = try SharedModelContainer.create()
        } catch {
            fatalError("Could not create the model container: \(error)")
        }
        BotStore(context: container.mainContext).seedIfEmpty()
        BackgroundTaskService.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(router)
                .environment(brain)
                .environment(preview)
                .environment(notifications)
                .task {
                    brain.pageInspector = preview
                    BackgroundTaskService.scheduleRefresh()
                }
        }
        .modelContainer(container)
    }
}
