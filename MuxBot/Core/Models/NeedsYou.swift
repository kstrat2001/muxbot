import Foundation

/// What needs you on this Mac: runs waiting for Approve or with a question
/// (`BotRun.needsYou`), less the ones you hid with the banner's ×. Hiding
/// is per item and machine-local (`LocalBotState`); the run, and the synced
/// `Bot.state`, are untouched. Something new needs you again.
@MainActor
enum NeedsYou {
    static func isDismissed(_ run: BotRun, in local: LocalBotState = .shared) -> Bool {
        guard let botId = run.bot?.id else { return false }
        return local[botId]?.dismissedRuns?.contains(run.id.uuidString) ?? false
    }

    /// Waiting on you and not hidden here.
    static func isWaiting(_ run: BotRun, in local: LocalBotState = .shared) -> Bool {
        run.needsYou && !isDismissed(run, in: local)
    }

    static func waiting(_ runs: [BotRun], in local: LocalBotState = .shared) -> [BotRun] {
        runs.filter { isWaiting($0, in: local) }
    }

    /// The thread's pinned banner, oldest first.
    /// The banner's line for one run: waiting for Approve, changes that
    /// weren't saved (no checkpoint), or a question.
    @MainActor static func bannerLine(for run: BotRun) -> String {
        if run.phase == .proposed { return String(localized: "Waiting for your Approve: \(run.task)") }
        if RunCardState.checkpointProblem(run) != nil { return String(localized: "\(run.crew.name)'s changes weren't saved: \(run.task)") }
        return String(localized: "\(run.crew.name) has a question: \(run.task)")
    }

    static func banner(_ runs: [BotRun], in local: LocalBotState = .shared) -> [BotRun] {
        waiting(runs, in: local).sorted { $0.createdAt < $1.createdAt }
    }

    /// Hides these until something new needs you.
    static func dismiss(_ runs: [BotRun], in local: LocalBotState = .shared) {
        for run in runs {
            guard let botId = run.bot?.id else { continue }
            local.update(botId) { entry in
                var ids = Set(entry.dismissedRuns ?? [])
                ids.insert(run.id.uuidString)
                // Keep only ids that still belong to this bot's runs.
                let live = Set((run.bot?.runs ?? []).map(\.id.uuidString))
                entry.dismissedRuns = ids.filter(live.contains).sorted()
            }
        }
    }

    /// The state a bot shows here: Needs you only while something not
    /// hidden waits; otherwise Working while a run runs, else as stored.
    static func shownState(_ bot: Bot, in local: LocalBotState = .shared) -> BotState {
        guard bot.state == .needsYou else { return bot.state }
        let runs = bot.runs ?? []
        if runs.contains(where: { isWaiting($0, in: local) }) { return .needsYou }
        return runs.contains { $0.phase.isActive } ? .working : .ready
    }
}
