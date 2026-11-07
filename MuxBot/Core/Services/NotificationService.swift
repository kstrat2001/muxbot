import Foundation
import UserNotifications

/// Local notifications, e.g. "a role needs you". Nothing schedules them yet.
@MainActor @Observable
final class NotificationService {
    private let center = UNUserNotificationCenter.current()

    var isAuthorized = false

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            isAuthorized = granted
            return granted
        } catch {
            return false
        }
    }

    func checkAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    /// Tell the user a role is waiting on them.
    func notifyNeedsYou(roleId: UUID, roleName: String, detail: String) {
        guard isAuthorized else { return }
        schedule(id: "needs-you-\(roleId)", title: "\(roleName) needs you", body: detail, after: 1)
    }

    func cancel(roleId: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: ["needs-you-\(roleId)"])
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }

    private func schedule(id: String, title: String, body: String, after seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(seconds, 1), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
