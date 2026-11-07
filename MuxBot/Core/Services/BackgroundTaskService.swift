import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Periodic background refresh (iOS only). Placeholder: will poll darkmux
/// for role status once networking lands; today it only reschedules.
enum BackgroundTaskService {
    static let refreshTaskId = "com.darklyenergized.darkmuxapp.refresh"

    @MainActor
    static func register() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: .main) { task in
            scheduleRefresh()
            task.setTaskCompleted(success: true)
        }
        #endif
    }

    static func scheduleRefresh() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }
}
