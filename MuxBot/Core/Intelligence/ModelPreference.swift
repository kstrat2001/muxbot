import Foundation

/// How a run's model is chosen. App-wide in Settings › Models, overridable
/// per bot (`LocalBotState.modelMode`); machine-local, since the models a
/// Mac can run differ.
enum ModelMode: Equatable, Hashable, Sendable {
    /// The app picks: the first in the Auto order that's running, and the
    /// next one after a done-when that wasn't met.
    case auto
    /// The dispatch card asks, with Auto's pick preselected.
    case ask
    /// Always this model; a done-when not met offers the next one, never
    /// switches by itself.
    case model(String)

    /// "auto", "ask" or "model:<name>".
    var stored: String {
        switch self {
        case .auto: "auto"
        case .ask: "ask"
        case let .model(name): "model:\(name)"
        }
    }

    /// The model a saved "Always <name>" names when this machine doesn't
    /// list it: its picker still needs a row for it, or it shows blank.
    static func unlistedModel(_ mode: ModelMode?, listed: [String]) -> String? {
        guard case let .model(name)? = mode, !listed.contains(name) else { return nil }
        return name
    }

    init?(stored: String?) {
        switch stored {
        case "auto"?: self = .auto
        case "ask"?: self = .ask
        case let s? where s.hasPrefix("model:"): self = .model(String(s.dropFirst("model:".count)))
        default: return nil
        }
    }
}

/// Settings › Models for one darkmux machine: its mode (its models differ
/// from another's) and the Auto order, shared (names; one a machine doesn't
/// list is skipped). Kept in `ModelSettingsStore`.
struct ModelSettings: Equatable, Sendable {
    var mode: ModelMode = .auto
    /// Coder's models by profile name, fastest first, then the stronger one
    /// a run moves to when its done-when isn't met.
    var order: [String] = ModelSettings.defaultOrder

    static let defaultOrder = ["flint-rec", "q38-27b-tensorfold"]

    /// A bot's own mode when it has one, else the app's.
    func mode(forBot botMode: ModelMode?) -> ModelMode { botMode ?? mode }
}

/// Where model settings live: they're about target machines, not this
/// device, so the phone and the Mac share them. iCloud key-value storage
/// when sync is on, this device's defaults otherwise.
protocol KeyValueBacking: AnyObject {
    func string(forKey key: String) -> String?
    func array(forKey key: String) -> [Any]?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    /// Every key it holds (to remove a deleted bot's settings).
    var storedKeys: [String] { get }
}

extension UserDefaults: KeyValueBacking {
    var storedKeys: [String] { Array(dictionaryRepresentation().keys) }
}
extension NSUbiquitousKeyValueStore: KeyValueBacking {
    var storedKeys: [String] { Array(dictionaryRepresentation.keys) }
}

final class ModelSettingsStore: @unchecked Sendable {
    let backing: any KeyValueBacking
    private let isICloud: Bool

    init(backing: any KeyValueBacking, isICloud: Bool = false) {
        self.backing = backing
        self.isICloud = isICloud
    }

    /// iCloud when sync is on (`MUXBOT_CLOUD_SYNC`) and the app has the
    /// key-value entitlement (`com.apple.developer.ubiquity-kvstore-identifier`).
    static func usesICloud(cloudSync: Bool, hasKeyValueEntitlement: Bool) -> Bool {
        cloudSync && hasKeyValueEntitlement
    }

    static let shared: ModelSettingsStore = {
        // Under tests (unit or a UI-test launch): never iCloud, never the
        // app's own defaults.
        if TestIsolation.isTesting {
            let suite = TestIsolation.isUITesting ? nil : UserDefaults(suiteName: "muxbot-tests-models")
            return ModelSettingsStore(backing: suite ?? TestIsolation.defaults)
        }
        let sync = (Bundle.main.object(forInfoDictionaryKey: "MuxBotCloudSync") as? String) == "YES"
        let kvs = (Bundle.main.object(forInfoDictionaryKey: "MuxBotKeyValueSync") as? String) == "YES"
        if usesICloud(cloudSync: sync, hasKeyValueEntitlement: kvs) {
            NSUbiquitousKeyValueStore.default.synchronize()
            return ModelSettingsStore(backing: NSUbiquitousKeyValueStore.default, isICloud: true)
        }
        return ModelSettingsStore(backing: UserDefaults.standard)
    }()

    private static let orderKey = "models.order"
    private static let machineIdKey = "models.machine.id"
    private static let machineNameKey = "models.machine.name"

    /// The darkmux machine last heard from, shared with your other devices.
    var lastMachine: DarkmuxClient.Machine? {
        get {
            guard let id = backing.string(forKey: Self.machineIdKey), !id.isEmpty else { return nil }
            return DarkmuxClient.Machine(id: id, name: backing.string(forKey: Self.machineNameKey) ?? id)
        }
        set {
            if let newValue {
                backing.set(newValue.id, forKey: Self.machineIdKey)
                backing.set(newValue.name, forKey: Self.machineNameKey)
            } else {
                backing.removeObject(forKey: Self.machineIdKey)
                backing.removeObject(forKey: Self.machineNameKey)
            }
            flush()
        }
    }
    private func modeKey(_ machine: String) -> String { "models.mode.\(machine)" }
    private func botKey(_ bot: UUID, _ machine: String) -> String { "models.bot.\(bot.uuidString).\(machine)" }

    func settings(machine: String) -> ModelSettings {
        ModelSettings(mode: ModelMode(stored: backing.string(forKey: modeKey(machine))) ?? .auto,
                      order: (backing.array(forKey: Self.orderKey) as? [String]) ?? ModelSettings.defaultOrder)
    }

    func save(_ settings: ModelSettings, machine: String) {
        backing.set(settings.mode.stored, forKey: modeKey(machine))
        backing.set(settings.order, forKey: Self.orderKey)
        flush()
    }

    /// A bot's own mode on a machine; nil follows Settings.
    func botMode(bot: UUID, machine: String) -> ModelMode? {
        ModelMode(stored: backing.string(forKey: botKey(bot, machine)))
    }

    func setBotMode(_ mode: ModelMode?, bot: UUID, machine: String) {
        if let mode { backing.set(mode.stored, forKey: botKey(bot, machine)) } else { backing.removeObject(forKey: botKey(bot, machine)) }
        flush()
    }

    /// A deleted bot's own modes, on every machine.
    func removeBotModes(bot: UUID) {
        let prefix = "models.bot.\(bot.uuidString)."
        let keys = backing.storedKeys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }
        for key in keys { backing.removeObject(forKey: key) }
        flush()
    }

    private func flush() {
        if isICloud { NSUbiquitousKeyValueStore.default.synchronize() }
    }
}

/// The model a run goes with, and why; what the dispatch card shows.
struct ModelChoice: Equatable, Sendable {
    /// nil leaves it to darkmux.
    var profile: String?
    var reason: String
    /// Always ask: the card shows a picker with `profile` preselected.
    var ask = false
    /// The chosen model isn't usable here (said, never swapped).
    var unavailable: String? = nil
    /// Auto's pick, offered when `unavailable`.
    var suggestion: String? = nil
    /// A default model's run after a done-when not met: the model to offer.
    var offerNext: String? = nil
    /// A default model: stays on it after a done-when not met (it offers
    /// `offerNext` instead of switching).
    var stays = false

    /// `crew` names whose default darkmux falls back to (Coder, Reviewer…).
    static func resolve(mode: ModelMode, order: [String], listed: [DarkmuxClient.ProfileInfo],
                        previous: String?, rerunAfterNotMet: Bool, crew: String = CrewRole.coder.name) -> ModelChoice {
        switch mode {
        case .auto, .ask:
            var c = rerunAfterNotMet ? auto(next: previous, order: order, listed: listed, crew: crew) : auto(order: order, listed: listed, crew: crew)
            c.ask = mode == .ask
            return c
        case let .model(name):
            let entry = listed.first { $0.name == name }
            var c = ModelChoice(profile: name, reason: "your default model", stays: true)
            if entry == nil {
                c.unavailable = "\(name) isn't available to Mux Bot on this Mac."
            } else if entry?.reachable == false {
                c.unavailable = "\(name) isn't running on this Mac."
            }
            if c.unavailable != nil { c.suggestion = auto(order: order, listed: listed, crew: crew).profile.flatMap { $0 == name ? nil : $0 } }
            if rerunAfterNotMet {
                let next = ModelPreference.next(after: name, in: listed, order: order)
                let fallback = auto(order: order, listed: listed, crew: crew).profile
                c.offerNext = [next, fallback].compactMap { $0 }.first { $0 != name }
            }
            return c
        }
    }

    private static func auto(order: [String], listed: [DarkmuxClient.ProfileInfo], crew: String) -> ModelChoice {
        guard !listed.isEmpty else { return ModelChoice(profile: nil, reason: "darkmux picks (it didn't list models)") }
        let up = listed.filter(\.reachable).map(\.name)
        if let name = order.first(where: up.contains) {
            return ModelChoice(profile: name, reason: "first in your Auto order that's running")
        }
        return ModelChoice(profile: ModelPreference.first(in: listed, order: order), reason: "darkmux's default for \(crew)")
    }

    private static func auto(next previous: String?, order: [String], listed: [DarkmuxClient.ProfileInfo], crew: String) -> ModelChoice {
        guard let previous, order.contains(previous) else { return auto(order: order, listed: listed, crew: crew) }
        guard let next = ModelPreference.next(after: previous, in: listed, order: order) else { return auto(order: order, listed: listed, crew: crew) }
        guard next != previous else { return ModelChoice(profile: next, reason: "last in your Auto order") }
        return ModelChoice(profile: next, reason: "next in your Auto order, after a done-when that wasn't met")
    }
}

/// The Auto order applied to what darkmux lists (`GET /client/profiles`:
/// the role's own first, then every other local profile).
enum ModelPreference {
    /// The first in `order` that answers now, else darkmux's default (listed
    /// first) when it answers; nil leaves the choice to darkmux. A run never
    /// wanders to some other local model.
    static func first(in listed: [DarkmuxClient.ProfileInfo], order: [String] = ModelSettings.defaultOrder) -> String? {
        let up = listed.filter(\.reachable).map(\.name)
        return order.first(where: up.contains) ?? up.first.flatMap { listed.first?.name == $0 ? $0 : nil }
    }

    /// The one after `current` in `order` that answers; the last stays.
    /// When `current` itself doesn't answer, never `current`: the next one
    /// after its place in the order that does, else the strongest before it
    /// that does, else darkmux's default (nil when nothing answers).
    static func next(after current: String?, in listed: [DarkmuxClient.ProfileInfo], order: [String] = ModelSettings.defaultOrder) -> String? {
        let up = Set(listed.filter(\.reachable).map(\.name))
        guard let current else { return first(in: listed, order: order) }
        guard let i = order.firstIndex(of: current) else { return up.contains(current) ? current : first(in: listed, order: order) }
        if let after = order[(i + 1)...].first(where: up.contains) { return after }
        if up.contains(current) { return current }
        return order[..<i].last(where: up.contains) ?? first(in: listed, order: order)
    }
}

/// How the last look at darkmux's models went.
enum ModelListing: Equatable, Sendable {
    case loading
    case listed
    case failed(String)
}

/// A model in Settings › Models: its description's leading phrase as the
/// name with the id under it (the id alone without one), and whether it's
/// running on this machine.
struct ModelRow: Equatable {
    enum Status: Equatable {
        case running, loadsWhenUsed, notRunning, notHere, unknown

        var label: String? {
            switch self {
            case .running: String(localized: "Running")
            case .loadsWhenUsed: String(localized: "Loads when used")
            case .notRunning: String(localized: "Not running")
            case .notHere: String(localized: "Not on this Mac")
            case .unknown: nil
            }
        }
    }

    var name: String
    var title: String
    var subtitle: String?
    /// The whole description, for hover.
    var detail: String?
    var status: Status

    init(name: String, listed: [DarkmuxClient.ProfileInfo], listing: ModelListing) {
        self.name = name
        let profile = listed.first { $0.name == name }
        let description = profile?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        detail = description?.isEmpty == false ? description : nil
        if let phrase = detail.map(Self.leadingPhrase), !phrase.isEmpty, phrase != name {
            title = phrase
            subtitle = name
        } else {
            title = name
            subtitle = nil
        }
        guard listing == .listed else { status = .unknown; return }
        guard let profile else { status = .notHere; return }
        if !profile.reachable { status = .notRunning }
        else if profile.loaded == false { status = .loadsWhenUsed }
        else { status = .running }
    }

    /// Up to the first ": ", ". ", " — " or line break, at most about 50
    /// characters (cut at a word).
    static func leadingPhrase(_ text: String) -> String {
        var phrase = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        for stop in [": ", ". ", " — "] {
            if let r = phrase.range(of: stop) { phrase = String(phrase[..<r.lowerBound]) }
        }
        phrase = phrase.trimmingCharacters(in: .whitespaces)
        if phrase.hasSuffix(".") { phrase.removeLast() }
        let cap = 50
        guard phrase.count > cap else { return phrase }
        let head = phrase.prefix(cap)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}
