import Foundation

/// Which model a run goes to darkmux with. The app decides per run; darkmux
/// says which profiles this app may use here and which answer now (`GET
/// /client/profiles`: the role's own first, then every other local one).
/// This is the one place the order is decided.
enum ModelPreference {
    /// Coder's models by profile name, fastest first, then the stronger one
    /// a run moves to when its done-when isn't met. Names this machine
    /// doesn't list are skipped; with none listed, darkmux's own default
    /// for the role (what it lists first) is used, and a run never wanders
    /// to some other local model.
    static let coder = ["flint-rec", "q38-27b-tensorfold"]

    /// The first preferred profile that answers now, else darkmux's default
    /// (listed first) when it answers; nil leaves the choice to darkmux.
    static func first(in listed: [DarkmuxClient.ProfileInfo]) -> String? {
        let up = listed.filter(\.reachable).map(\.name)
        return coder.first(where: up.contains) ?? up.first.flatMap { listed.first?.name == $0 ? $0 : nil }
    }

    /// The preferred profile after `current` (a done-when that wasn't met
    /// runs on the next, stronger one); the last stays the last.
    static func next(after current: String?, in listed: [DarkmuxClient.ProfileInfo]) -> String? {
        let up = listed.filter(\.reachable).map(\.name)
        let order = coder.filter(up.contains)
        guard let current else { return first(in: listed) }
        guard let i = order.firstIndex(of: current) else { return current }
        return i + 1 < order.count ? order[i + 1] : order[i]
    }
}
