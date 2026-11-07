import Foundation

/// The Activity tab's three groups: what needs you, what's running, and what
/// recently finished or stopped. Newest first in each.
struct ActivitySections {
    var needsYou: [BotRun]
    var running: [BotRun]
    var finished: [BotRun]

    var isEmpty: Bool { needsYou.isEmpty && running.isEmpty && finished.isEmpty }

    /// `isWaiting` leaves out what you hid with a banner's × (they're
    /// listed with the finished ones).
    @MainActor
    init(runs: [BotRun], recentLimit: Int = 20, isWaiting: (BotRun) -> Bool = { NeedsYou.isWaiting($0) }) {
        let newest = runs.sorted { $0.createdAt > $1.createdAt }
        needsYou = newest.filter(isWaiting)
        running = newest.filter { $0.phase.isActive }
        finished = Array(newest.filter { $0.phase.isClosed || ($0.needsYou && !isWaiting($0)) }.prefix(recentLimit))
    }
}
