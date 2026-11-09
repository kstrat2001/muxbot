import Foundation

/// What a notification says when a run needs you, and the badge count.
struct RunNotice: Equatable, Sendable {
    var title: String
    var body: String

    /// Results and failures notify; nothing else does.
    @MainActor
    static func make(for run: BotRun) -> RunNotice? {
        let bot = run.bot?.name ?? LeadBot.name
        switch run.phase {
        case .result:
            return RunNotice(title: "\(bot): result ready", body: "\(run.task). \(run.summary)")
        case .failed:
            return RunNotice(title: "\(bot): didn't finish", body: "\(run.task). \(run.summary)")
        default:
            return nil
        }
    }

    /// Runs waiting on a decision of yours.
    @MainActor
    static func badgeCount(_ runs: [BotRun]) -> Int {
        NeedsYou.waiting(runs).count
    }
}
