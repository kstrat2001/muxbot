import Foundation

/// The settings Mux Bot can explain and show a live switch for in the chat.
enum GuideSettingID: String, Codable, Sendable, CaseIterable {
    case modelMode = "models.mode"
    case notifications
    case sync
    /// darkmux's own: which models paired apps may use. Read-only here
    /// (changed on the Mac) until darkmux has a way to set it.
    case darkmuxModels = "darkmux.models"
}

struct GuideSetting: Sendable {
    var id: GuideSettingID
    var title: String
    /// The help article that explains it.
    var article: String
    /// Phrases that name it.
    var phrases: [String]
    /// A darkmux setting: shown only once paired, never switched here.
    var isDarkmux = false
    /// Set when the app is built; shown, never switched.
    var isReadOnly = false
}

enum GuideSettings {
    /// Most specific first: "which models can Mux Bot use" is darkmux's, not
    /// the model choice.
    static let all: [GuideSetting] = [
        GuideSetting(id: .darkmuxModels, title: String(localized: "Models apps may use"), article: "models",
                     phrases: ["models can mux bot", "models mux bot can", "models can apps", "models apps can", "models apps may",
                               "allowed models", "which models are allowed", "hosted model", "models it may use", "models can it use"],
                     isDarkmux: true, isReadOnly: true),
        GuideSetting(id: .modelMode, title: String(localized: "Choosing the model"), article: "models",
                     phrases: ["always ask", "auto order", "model choice", "choosing the model", "choose the model", "pick the model",
                               "picks the model", "default model", "model mode", "which model runs", "auto mode", "model setting"]),
        GuideSetting(id: .notifications, title: String(localized: "Notifications"), article: "notifications",
                     phrases: ["notification", "notify", "alerts"]),
        GuideSetting(id: .sync, title: String(localized: "iCloud sync"), article: "sync",
                     phrases: ["sync", "icloud"], isReadOnly: true),
    ]

    static func setting(_ id: GuideSettingID) -> GuideSetting { all.first { $0.id == id }! }

    static func match(_ lower: String) -> GuideSettingID? {
        all.first { $0.phrases.contains(where: lower.contains) }?.id
    }

    /// "switch", "turn off", "set it to": asking for a change, not about it.
    static func isChangeRequest(_ lower: String) -> Bool {
        ["switch", "turn on", "turn off", "turn it", "enable", "disable", "change", "set it", "set the", "set my", "make it", "use always", "toggle", "stop "]
            .contains(where: lower.contains)
    }

    // MARK: Live values

    /// Saves the mode for darkmux's machine; false (nothing saved) until
    /// darkmux has said which machine it is.
    @discardableResult @MainActor static func setModelMode(_ mode: ModelMode, runs: RunCoordinator) -> Bool {
        guard let machine = runs.knownMachine else { return false }
        var settings = runs.settingsStore.settings(machine: machine.id)
        settings.mode = mode
        runs.settingsStore.save(settings, machine: machine.id)
        return true
    }

    static func describe(_ mode: ModelMode) -> String {
        switch mode {
        case .auto: String(localized: "Auto")
        case .ask: String(localized: "Always ask")
        case let .model(name): String(localized: "Always \(name)")
        }
    }

    static var syncIsOn: Bool { (Bundle.main.object(forInfoDictionaryKey: "MuxBotCloudSync") as? String) == "YES" }
}
