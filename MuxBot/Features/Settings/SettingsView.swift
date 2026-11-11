import SwiftUI

/// Settings: a sidebar of pages (General, Computers, Models, GitHub). The
/// Mac's Settings window shows the page beside the list; iPhone and iPad
/// open each page from the list.
struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var stored = SettingsTab.general.rawValue

    var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            List(SettingsTab.allCases, selection: selection) { page in
                Label(page.title, systemImage: page.systemImage).tag(page)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            SettingsPage(page: current)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(current.title)
        .frame(width: 720, height: 520)
        #else
        List(SettingsTab.allCases) { page in
            NavigationLink {
                SettingsPage(page: page).navigationTitle(page.title)
            } label: {
                Label(page.title, systemImage: page.systemImage)
            }
        }
        .navigationTitle("Settings")
        #endif
    }

    private var current: SettingsTab { SettingsTab.stored(stored) }

    private var selection: Binding<SettingsTab?> {
        Binding(get: { current }, set: { if let page = $0 { stored = page.rawValue } })
    }
}

/// One Settings page.
struct SettingsPage: View {
    let page: SettingsTab

    var body: some View {
        switch page {
        case .general: GeneralSettingsView()
        case .computers: ComputersView()
        case .models: ModelSettingsView()
        case .github: GitHubSignInView()
        }
    }
}

/// Settings › General: notifications and the on-device model.
struct GeneralSettingsView: View {
    @Environment(BotBrain.self) private var brain
    @Environment(NotificationService.self) private var notifications
    @AppStorage(NotificationService.enabledKey) private var notify = true

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Tell me when a run has a result or didn't finish", isOn: $notify).tint(Color.brandGreen)
                if notify && notifications.isDenied {
                    Label("Notifications are blocked in System Settings › Notifications.", systemImage: "bell.slash")
                    Button("Open System Settings") { notifications.openSystemSettings() }
                } else if notify && !notifications.isAuthorized {
                    Button("Allow notifications") { Task { _ = await notifications.requestAuthorization() } }
                }
                #if os(macOS)
                Text("The Dock icon shows how many runs are waiting on you.")
                    .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                #endif
            }
            Section("On-device model") {
                if let reason = brain.onDeviceUnavailableReason {
                    Label("Not available: \(reason).", systemImage: "exclamationmark.triangle")
                    Text("Bots fall back to simple keyword matching until it's available.")
                        .font(AppFont.footnote()).foregroundStyle(Color.secondaryText)
                } else {
                    Label("Apple Intelligence is ready. Bots answer on this device.", systemImage: "checkmark.circle.fill")
                        .labelStyle(.tintedIcon(Color.brandGreen))
                }
            }
        }
        .formStyle(.grouped)
        .task { await notifications.checkAuthorizationStatus() }
    }
}

/// Settings' pages, kept so a link can open the right one.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, computers, models, github
    static let key = "settingsTab"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .computers: String(localized: "Computers")
        case .models: String(localized: "Models")
        case .github: String(localized: "GitHub")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .computers: "desktopcomputer"
        case .models: "cpu"
        case .github: "person.badge.key"
        }
    }

    /// The page a stored value opens, including the tab bar's old names
    /// (darkmux was Computers; Notifications and the on-device model are
    /// General now).
    static func stored(_ raw: String) -> SettingsTab {
        if let page = SettingsTab(rawValue: raw) { return page }
        return raw == "darkmux" ? .computers : .general
    }

    /// Opens Settings on `tab` next time it's shown (set before opening).
    static func select(_ tab: SettingsTab, in defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: key)
    }
}
