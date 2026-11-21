import Foundation
import Testing
@testable import MuxBot

/// #144 step 1: the task's state comes only from darkmux's status and the
/// review on GitHub, and every action is allowed or refused by one table.
struct TaskStateTests {
    private typealias F = TaskState.Facts
    private func review(_ standing: TaskReview.Standing = .ready, status: TaskState.Review.Status = .open, head: String = "abc") -> TaskState.Review {
        .init(status: status, head: head, standing: standing)
    }

    // MARK: State, row by row

    @Test func darkmuxNotAnsweringIsOfflineWhateverElseIsTrue() {
        #expect(TaskState.of(F(reachable: false, busy: true, head: "abc", pending: 3, review: review(status: .merged))) == .offline)
    }

    @Test func noChangesIsClean() {
        #expect(TaskState.of(F(head: "abc")) == .clean)
    }

    @Test func changesWithNoReviewAreChanged() {
        #expect(TaskState.of(F(head: "abc", pending: 2)) == .changed)
    }

    @Test func aHeldWorkCopyIsBusy() {
        #expect(TaskState.of(F(busy: true, head: "abc", pending: 2)) == .busy)
        #expect(TaskState.of(F(busy: true, head: "abc", review: review())) == .busy)
    }

    @Test func mergedAndClosedOnGitHubWinOverBusy() {
        #expect(TaskState.of(F(busy: true, head: "abc", review: review(status: .merged))) == .merged)
        #expect(TaskState.of(F(busy: true, head: "abc", review: review(status: .closed))) == .closed)
    }

    @Test func changesGitHubDoesNotHaveAreNotSent() {
        #expect(TaskState.of(F(head: "def", pending: 3, ahead: 1, review: review(head: "abc"))) == .notSent)
    }

    @Test func aReviewHeadThisWorkCopyDoesNotHaveIsChangedOnGitHub() {
        #expect(TaskState.of(F(head: "abc", pending: 2, review: review(head: "zzz"))) == .changedOnGitHub)
    }

    @Test func aConflictOrRulesWantingAnUpdateAreMainMoved() {
        #expect(TaskState.of(F(head: "abc", pending: 2, review: review(.conflict))) == .mainMoved)
        #expect(TaskState.of(F(head: "abc", pending: 2, review: review(.behind))) == .mainMoved)
    }

    @Test func gitHubHavingExactlyThisWorkCopyIsInReview() {
        for standing: TaskReview.Standing in [.ready, .checking, .needsReview, .notAllowed] {
            #expect(TaskState.of(F(head: "abc", pending: 2, review: review(standing))) == .inReview)
        }
    }

    @Test func theSameFactsGiveTheSameStateOnEveryDevice() {
        let facts = F(head: "abc", pending: 2, review: review())
        #expect(TaskState.of(facts) == TaskState.of(facts))
    }

    // MARK: The table

    private let all: [TaskState] = [.offline, .busy, .clean, .changed, .notSent, .changedOnGitHub, .mainMoved, .inReview, .merged, .closed]

    private func allowed(_ action: TaskState.Action, standing: TaskReview.Standing? = nil) -> Set<String> {
        Set(all.filter { $0.allows(action, standing: standing) }.map { "\($0)" })
    }

    @Test func checkAgainIsAlwaysThere() {
        #expect(allowed(.checkAgain).count == all.count)
    }

    @Test func mergeGoesAheadOnlyInReviewWithGitHubReady() {
        #expect(allowed(.merge, standing: .ready) == ["inReview"])
        #expect(allowed(.merge) == ["inReview"])
        for standing: TaskReview.Standing in [.checking, .needsReview, .notAllowed] {
            #expect(allowed(.merge, standing: standing).isEmpty)
            #expect(TaskState.inReview.refusal(.merge, standing: standing) != nil)
        }
    }

    @Test func mergeNeverTakesWorkGitHubDoesNotHaveOrSomeoneElsesCommits() {
        #expect(TaskState.notSent.refusal(.merge) != nil)
        #expect(TaskState.changedOnGitHub.refusal(.merge) != nil)
        #expect(TaskState.busy.refusal(.merge) != nil)
        #expect(TaskState.offline.refusal(.merge) != nil)
    }

    @Test func sendIsOnlyForChangesGitHubLacks() {
        #expect(allowed(.send) == ["notSent"])
    }

    @Test func reviewAndMergeOpensOnlyWhenThereAreChangesAndNoOpenReview() {
        #expect(allowed(.reviewAndMerge) == ["changed", "closed"])
    }

    @Test func undoWaitsOnSomeoneElsesCommitsAndNeverReachesIntoTheProject() {
        #expect(allowed(.undo) == ["changed", "notSent", "inReview", "mainMoved", "closed"])
    }

    @Test func bringInChangesOnlyWhenThereIsSomethingNew() {
        #expect(allowed(.bringInChanges) == ["changedOnGitHub", "mainMoved"])
    }

    @Test func theNextTaskStartsOnlyAfterThisOneIsDone() {
        #expect(allowed(.startNextTask) == ["clean", "merged", "closed"])
    }

    @Test func aBusyWorkCopyOnlyLetsYouLook() {
        let ok = TaskState.Action.allCases.filter { TaskState.busy.allows($0) }
        #expect(Set(ok.map { "\($0)" }) == ["seeChanges", "checkAgain"])
    }

    @Test func offlineOnlyChecksAgain() {
        let ok = TaskState.Action.allCases.filter { TaskState.offline.allows($0) }
        #expect(ok == [.checkAgain])
    }

    @Test func aMergedTaskStartsNoNewRunUntilTheNextTask() {
        #expect(!TaskState.merged.allows(.startRun))
        #expect(TaskState.closed.allows(.startRun))
    }

    @Test func everyRefusalIsAPlainSentence() {
        for state in all {
            for action in TaskState.Action.allCases {
                guard let text = state.refusal(action) else { continue }
                #expect(text.hasSuffix("."), "\(state) \(action): \(text)")
                for word in ["branch", "commit", "worktree", "rebase", "push", "409", "darkmux status"] {
                    #expect(!text.lowercased().contains(word), "\(state) \(action) says \(word)")
                }
            }
        }
    }
}
