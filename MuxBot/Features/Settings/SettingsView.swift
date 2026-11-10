import SwiftUI

/// The Mac's Settings window: the darkmux pairing, notifications, and the
/// on-device model's status.
struct SettingsView: View {
    @Environment(FleetConnection.self) private var connection
    @Environment(BotBrain.self) private var brain
    @Environment(NotificationService.self) private var notifications
    @AppStorage(NotificationService.enabledKey) private var notify = true
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.darkmux.rawValue

    var body: some View {
        TabView(selection: $tab) {
            Tab("darkmux", systemImage: "link", value: SettingsTab.darkmux.rawValue) {
                FleetPairingView()
            }
            Tab("Models", systemImage: "cpu", value: SettingsTab.models.rawValue) {
                ModelSettingsView()
            }
            Tab("GitHub", systemImage: "person.badge.key", value: SettingsTab.github.rawValue) {
                GitHubSignInView()
            }
            Tab("Notifications", systemImage: "bell", value: SettingsTab.notifications.rawValue) {
                Form {
                    Toggle("Tell me when a run has a result or didn't finish", isOn: $notify)
                    if notify && notifications.isDenied {
                        Label("Notifications are blocked in System Settings › Notifications.", systemImage: "bell.slash")
                        Button("Open System Settings") { notifications.openSystemSettings() }
                    } else if notify && !notifications.isAuthorized {
                        Button("Allow notifications") { Task { _ = await notifications.requestAuthorization() } }
                    }
                    Text("The Dock icon shows how many runs are waiting on you.")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
                .formStyle(.grouped)
                .task { await notifications.checkAuthorizationStatus() }
            }
            Tab("On-device model", systemImage: "apple.intelligence", value: SettingsTab.model.rawValue) {
                Form {
                    if let reason = brain.onDeviceUnavailableReason {
                        Label("Not available: \(reason).", systemImage: "exclamationmark.triangle")
                        Text("Bots fall back to simple keyword matching until it's available.")
                            .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                    } else {
                        Label("Apple Intelligence is ready. Bots answer on this device.", systemImage: "checkmark.circle.fill")
                            .labelStyle(.tintedIcon(Color.brandGreen))
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 520, height: 460)
    }
}

/// The Settings window's tabs, kept so a link can open the right one.
enum SettingsTab: String {
    case darkmux, models, github, notifications, model
    static let key = "settingsTab"
    /// Opens Settings on `tab` next time it's shown (set before opening).
    static func select(_ tab: SettingsTab, in defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: key)
    }
}
