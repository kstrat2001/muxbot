import Foundation
import SwiftData

/// Where a run is in the human-in-the-loop loop:
/// proposed → running → result → kept / tweaked (back to running) /
/// discarded; kept → PR opened or done.
enum RunPhase: String, Codable, Sendable {
    case proposed, canceled, running, result, kept, discarded, prOpened, done, failed

    /// Whether the run still needs a person to act on it.
    var awaitsYou: Bool { self == .proposed || self == .result || self == .kept }
    var isActive: Bool { self == .running }
    var isClosed: Bool { [.canceled, .discarded, .prOpened, .done, .failed].contains(self) }
}

enum RunEvent: Equatable, Sendable {
    case approve, cancel, finish(summary: String), keep, tweak, discard, openPR, skipPR, stop
    case fail(reason: String, details: String?)
}

extension RunPhase {
    /// The phase after `event`, or nil when the event isn't allowed here.
    func next(on event: RunEvent) -> RunPhase? {
        switch (self, event) {
        case (.proposed, .approve): .running
        case (.proposed, .cancel): .canceled
        case (.running, .finish): .result
        case (.result, .keep): .kept
        case (.result, .tweak): .running
        case (.result, .discard): .discarded
        case (.kept, .openPR): .prOpened
        case (.kept, .skipPR): .done
        case (.running, .stop): .canceled
        case (.running, .fail): .failed
        default: nil
        }
    }
}

/// One piece of work a bot dispatches to its darkmux crew, followed
/// through approval, the live run, the result, and what you decide.
@Model
final class BotRun {
    var id: UUID = UUID()
    var task: String = ""
    /// What darkmux is told (the task plus context such as an issue's
    /// body). The cards show `task`; nil sends `task` as is.
    var brief: String?
    var crew: CrewRole = CrewRole.coder
    var phase: RunPhase = RunPhase.proposed
    var summary: String = ""
    var tweaks: Int = 0
    /// When you approved it, and when it stopped running.
    var startedAt: Date?
    var finishedAt: Date?
    /// Set when the run was sent to darkmux for real (not simulated).
    var darkmuxWorkId: String?
    /// The crew's full report (markdown), shown collapsed.
    var notes: String?
    /// Files the run changed ("path +a −r" lines) and the diff, from darkmux.
    var changedFiles: [String] = []
    var diff: String?
    /// For a run that didn't finish: the log, without darkmux plumbing.
    var details: String?
    /// After Keep: the branch and commit darkmux committed the changes to.
    var keptBranch: String?
    var keptCommit: String?
    var createdAt: Date = Date()
    var bot: Bot?

    /// Needs you (0), running (1), finished (2): the Activity table's default order.
    var statusRank: Int { phase.awaitsYou ? 0 : phase.isActive ? 1 : 2 }

    var durationSeconds: Double? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Sort keys for the Activity table (Optional isn't Comparable).
    var botName: String { bot?.name ?? "" }
    var crewName: String { crew.name }
    var durationSort: Double { durationSeconds ?? -1 }

    init(task: String, crew: CrewRole) {
        self.task = task
        self.crew = crew
    }
}
