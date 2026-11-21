import Foundation

/// The one answer to "what is this task doing, and what may I do with it?"
/// (#144, step 1). It's worked out from facts every device can see, never
/// from what one device remembers: darkmux's view of the work copy (its
/// `status`, darkmux #3681) and the pull request on GitHub. Any Mac,
/// iPhone or iPad that reads the same facts gets the same state and the
/// same buttons (Kain, 2026-11-16).
///
/// Pure: no I/O, no stores. The shelf and the review card read it in step 2;
/// nothing outside `allows` may offer an action.
enum TaskState: Equatable, Sendable {
    /// darkmux on the Mac that holds the work copy doesn't answer.
    case offline
    /// A run, a git step, a hand edit or a reinstall holds the work copy.
    case busy
    /// No changes in this task yet.
    case clean
    /// Changes saved here, not in a review yet.
    case changed
    /// In review, with changes here that GitHub doesn't have yet.
    case notSent
    /// In review, and the review on GitHub has commits this work copy doesn't.
    case changedOnGitHub
    /// In review, and the project moved on in a way that blocks merging
    /// (a conflict, or rules that want it brought up to date).
    case mainMoved
    /// In review, GitHub has exactly this work copy's changes.
    case inReview
    /// GitHub confirmed the merge.
    case merged
    /// The review was closed on GitHub without merging.
    case closed

    /// What the pull request looks like on GitHub, as read just now.
    struct Review: Equatable, Sendable {
        enum Status: Equatable, Sendable { case open, closed, merged }
        var status: Status
        /// The head commit GitHub has for the review's branch.
        var head: String
        /// GitHub's word on merging (`TaskReview.standing`).
        var standing: TaskReview.Standing
    }

    /// Everything the state is made of. All of it comes from darkmux's
    /// `status` and GitHub; none of it from `LocalBotState`.
    struct Facts: Equatable, Sendable {
        /// darkmux answered the status read.
        var reachable: Bool = true
        /// Something holds the work copy's lock (darkmux's 409 busy, or a
        /// run darkmux reports going).
        var busy: Bool = false
        /// The work copy's head commit.
        var head: String?
        /// Commits in this task that aren't in the project's main version.
        var pending: Int = 0
        /// Commits here that the task's branch on GitHub doesn't have.
        var ahead: Int = 0
        /// The review, when one was opened for this task.
        var review: Review?
    }

    static func of(_ facts: Facts) -> TaskState {
        guard facts.reachable else { return .offline }
        if let review = facts.review {
            switch review.status {
            case .merged: return .merged
            case .closed: return .closed
            case .open: break
            }
            if facts.busy { return .busy }
            if facts.ahead > 0 { return .notSent }
            if review.head != facts.head { return .changedOnGitHub }
            switch review.standing {
            case .conflict, .behind: return .mainMoved
            default: return .inReview
            }
        }
        if facts.busy { return .busy }
        return facts.pending > 0 ? .changed : .clean
    }

    /// Everything a person can ask of a task from the shelf or the review card.
    enum Action: CaseIterable, Sendable {
        case startRun
        case seeChanges
        case undo
        case reviewAndMerge
        case send
        case merge
        case bringInChanges
        case startNextTask
        case checkAgain
    }

    /// nil when the action may go ahead now; otherwise the one plain
    /// sentence the app says instead. Merge going ahead here means its
    /// checks passed and it merges at once, with no confirmation (Kain,
    /// 2026-11-16); GitHub refusing it then is reported the same way.
    func refusal(_ action: Action, standing: TaskReview.Standing? = nil) -> String? {
        if action == .checkAgain { return nil }
        switch self {
        case .offline:
            return String(localized: "darkmux on the Mac with this project isn't answering, so nothing can change right now.")
        case .busy:
            return action == .seeChanges ? nil : String(localized: "Wait for the change that's going now to finish.")
        default: break
        }
        switch action {
        case .checkAgain:
            return nil
        case .startRun:
            switch self {
            case .merged: return String(localized: "This task was merged. Start the next one first.")
            default: return nil
            }
        case .seeChanges:
            return self == .clean || self == .merged
                ? String(localized: "There are no changes in this task yet.") : nil
        case .undo:
            switch self {
            case .changed, .notSent, .inReview, .mainMoved, .closed: return nil
            case .changedOnGitHub: return String(localized: "Someone changed this review on GitHub. Bring in their changes before undoing anything here.")
            case .merged: return String(localized: "These changes are already in the project. Undo them in a new task.")
            default: return String(localized: "There's nothing to undo yet.")
            }
        case .reviewAndMerge:
            switch self {
            case .changed, .closed: return nil
            case .clean: return String(localized: "There are no changes to review yet.")
            case .merged: return String(localized: "This task was merged. Start the next one first.")
            default: return String(localized: "This task is already in review.")
            }
        case .send:
            return self == .notSent ? nil : String(localized: "GitHub already has every change in this task.")
        case .merge:
            switch self {
            case .inReview:
                if let standing, standing != .ready { return standing.sentence ?? String(localized: "GitHub isn't ready to merge this yet.") }
                return nil
            case .notSent: return String(localized: "Some changes haven't reached GitHub yet. They're sent first, then you can merge.")
            case .changedOnGitHub: return String(localized: "Someone changed this review on GitHub. Look at their changes before merging.")
            case .mainMoved: return (standing ?? .conflict).sentence
            case .merged: return String(localized: "Merged.")
            case .closed: return TaskReview.Standing.closed.sentence
            default: return String(localized: "Open a review first.")
            }
        case .bringInChanges:
            switch self {
            case .changedOnGitHub, .mainMoved: return nil
            default: return String(localized: "There's nothing new to bring in.")
            }
        case .startNextTask:
            switch self {
            case .merged, .closed, .clean: return nil
            default: return String(localized: "Finish this task first: merge it, or close its review on GitHub.")
            }
        }
    }

    func allows(_ action: Action, standing: TaskReview.Standing? = nil) -> Bool {
        refusal(action, standing: standing) == nil
    }
}
