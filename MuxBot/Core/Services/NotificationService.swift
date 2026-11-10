import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Local notifications when a run has a result or didn't finish, and the
/// app badge (runs waiting on you). On by default; off in Settings.
@MainActor @Observable
final class NotificationService {
    private let center = UNUserNotificationCenter.current()

    var isAuthorized = false
    /// You said no (or turned them off) in System Settings: asking again
    /// does nothing, so the app points there instead.
    var isDenied = false

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            isAuthorized = granted
            await checkAuthorizationStatus()
            return granted
        } catch {
            return false
        }
    }

    func checkAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        isAuthorized = [.authorized, .provisional].contains(settings.authorizationStatus)
        isDenied = settings.authorizationStatus == .denied
    }

    static let enabledKey = "notifyRuns"
    /// Settings toggle; on unless turned off.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// A run finished with a result or didn't finish: tell the user.
    func post(_ notice: RunNotice, runId: UUID) async {
        guard Self.isEnabled else { return }
        if !isAuthorized { _ = await requestAuthorization() }
        guard isAuthorized else { return }
        schedule(id: "run-\(runId)", title: notice.title, body: notice.body, after: 1)
    }

    /// The app badge: runs waiting on you (the Dock icon on macOS).
    func setBadge(_ count: Int) {
        #if os(macOS)
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        #else
        center.setBadgeCount(count) { _ in }
        #endif
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

extension NotificationService {
    /// What the guide's card says after the switch moves.
    nonisolated static func cardText(enabled: Bool, denied: Bool) -> String {
        guard enabled else { return String(localized: "Notifications are off.") }
        return denied
            ? String(localized: "Notifications are on here, but blocked in System Settings › Notifications, so none show.")
            : String(localized: "Notifications are on.")
    }

    /// System Settings › Notifications (this app's page where it can).
    func openSystemSettings() {
        #if os(macOS)
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") { NSWorkspace.shared.open(url) }
        #else
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}
