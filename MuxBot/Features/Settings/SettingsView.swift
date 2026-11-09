import SwiftUI

/// The Mac's Settings window: the darkmux pairing, notifications, and the
/// on-device model's status.
struct SettingsView: View {
    @Environment(FleetConnection.self) private var connection
    @Environment(BotBrain.self) private var brain
    @Environment(NotificationService.self) private var notifications
    @AppStorage(NotificationService.enabledKey) private var notify = true

    var body: some View {
        TabView {
            Tab("darkmux", systemImage: "link") {
                FleetPairingView()
            }
            Tab("Models", systemImage: "cpu") {
                ModelSettingsView()
            }
            Tab("GitHub", systemImage: "person.badge.key") {
                GitHubSignInView()
            }
            Tab("Notifications", systemImage: "bell") {
                Form {
                    Toggle("Tell me when a run has a result or didn't finish", isOn: $notify)
                    if notify && !notifications.isAuthorized {
                        Button("Allow notifications") { Task { _ = await notifications.requestAuthorization() } }
                    }
                    Text("The Dock icon shows how many runs are waiting on you.")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                }
                .formStyle(.grouped)
                .task { await notifications.checkAuthorizationStatus() }
            }
            Tab("On-device model", systemImage: "apple.intelligence") {
                Form {
                    if let reason = brain.onDeviceUnavailableReason {
                        Label("Not available: \(reason).", systemImage: "exclamationmark.triangle")
                        Text("Bots fall back to simple keyword matching until it's available.")
                            .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                    } else {
                        Label("Apple Intelligence is ready. Bots answer on this device.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.brandGreen)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 520, height: 460)
    }
}
