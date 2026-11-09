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
        // Everything else is finished: closed runs, committed results (and
        // runs an earlier build kept), and what you hid with the banner's ×.
        finished = Array(newest.filter { !isWaiting($0) && !$0.phase.isActive }.prefix(recentLimit))
    }
}
