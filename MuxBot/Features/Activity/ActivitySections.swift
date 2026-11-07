import Foundation

/// The Activity tab's three groups: what needs you, what's running, and what
/// recently finished or stopped. Newest first in each.
struct ActivitySections {
    var needsYou: [BotRun]
    var running: [BotRun]
    var finished: [BotRun]

    var isEmpty: Bool { needsYou.isEmpty && running.isEmpty && finished.isEmpty }

    init(runs: [BotRun], recentLimit: Int = 20) {
        let newest = runs.sorted { $0.createdAt > $1.createdAt }
        needsYou = newest.filter { $0.phase.awaitsYou }
        running = newest.filter { $0.phase.isActive }
        finished = Array(newest.filter { $0.phase.isClosed }.prefix(recentLimit))
    }
}
