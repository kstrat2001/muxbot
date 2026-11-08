import Foundation

/// Which model a run goes to darkmux with. The app decides per run; darkmux
/// says which profiles this app may use here and which answer now (`GET
/// /client/profiles`, in the order the owner granted them: fastest first is
/// the convention). This is the one place that order is applied.
enum ModelPreference {
    /// The first granted profile whose server answers now; nil leaves it to
    /// darkmux's own default for the role.
    static func first(in listed: [DarkmuxClient.ProfileInfo]) -> String? {
        listed.first(where: \.reachable)?.name
    }

    /// The one after `current` (a done-when that wasn't met runs on the next,
    /// stronger model); the last stays the last.
    static func next(after current: String?, in listed: [DarkmuxClient.ProfileInfo]) -> String? {
        let up = listed.filter(\.reachable).map(\.name)
        guard let current, let i = up.firstIndex(of: current) else { return up.first }
        return i + 1 < up.count ? up[i + 1] : up[i]
    }
}
