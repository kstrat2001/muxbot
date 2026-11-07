import SwiftUI
import SwiftData

@main
struct MuxBotApp: App {
    @State private var router = AppRouter()
    @State private var radio = RadioPlanner()
    @State private var llm = OnDeviceLLMService()
    @State private var notifications = NotificationService()

    private let container: ModelContainer

    init() {
        do {
            container = try SharedModelContainer.create()
        } catch {
            fatalError("Could not create the model container: \(error)")
        }
        RoleStore(context: container.mainContext).seedIfEmpty()
        BackgroundTaskService.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(router)
                .environment(radio)
                .environment(llm)
                .environment(notifications)
                .task { BackgroundTaskService.scheduleRefresh() }
        }
        .modelContainer(container)
    }
}
