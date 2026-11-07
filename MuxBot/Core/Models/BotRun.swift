import Foundation
import SwiftData

/// Where a run is in the human-in-the-loop loop:
/// proposed → running → result → kept / tweaked (back to running) /
/// discarded; kept → PR opened or done.
enum RunPhase: String, Codable, Sendable {
    case proposed, canceled, running, result, kept, discarded, prOpened, done

    /// Whether the run still needs a person to act on it.
    var awaitsYou: Bool { self == .proposed || self == .result || self == .kept }
    var isActive: Bool { self == .running }
    var isClosed: Bool { [.canceled, .discarded, .prOpened, .done].contains(self) }
}

enum RunEvent: Equatable, Sendable {
    case approve, cancel, finish(summary: String), keep, tweak, discard, openPR, skipPR, closeSimulation
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
        case (.result, .closeSimulation): .done
        default: nil
        }
    }
}

/// One piece of work a bot dispatches to its darkmux crew, followed
/// through approval, the live run, the result, and what you decide.
/// Sample data only until the fleet is connected.
@Model
final class BotRun {
    var id: UUID = UUID()
    var task: String = ""
    var crew: CrewRole = CrewRole.coder
    var phase: RunPhase = RunPhase.proposed
    var summary: String = ""
    /// The live preview URL, once the run has one.
    var previewURL: String?
    var tweaks: Int = 0
    /// Set when the run was sent to darkmux for real (not simulated).
    var darkmuxWorkId: String?
    /// Nothing really ran: the app isn't paired with darkmux (or can't
    /// send this run). Shown as a simulation, closed without a decision.
    var isSimulated: Bool = false
    var createdAt: Date = Date()
    var bot: Bot?

    init(task: String, crew: CrewRole) {
        self.task = task
        self.crew = crew
    }
}
