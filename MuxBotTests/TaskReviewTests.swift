import Foundation
import Testing
@testable import MuxBot

/// Tasks and review, step one: the Reviewer's answer splits into items (or
/// is shown as is), GitHub's merge state reads as one plain outcome, and a
/// new task after a merge asks darkmux for a fresh work copy.
struct TaskReviewTests {
    @Test func aNumberedListSplitsIntoItems() {
        let answer = """
            1. src/App.tsx: the header's padding also applies on the Contact page.
            2. **src/index.css**: a color is written twice.
               Keep the second one.
            """
        let parsed = TaskReview.parse(answer)
        #expect(parsed.raw == nil)
        #expect(parsed.items == ["src/App.tsx: the header's padding also applies on the Contact page.",
                                 "src/index.css: a color is written twice. Keep the second one."])
    }

    @Test func nothingToChangeIsAnEmptyList() {
        #expect(TaskReview.parse("Nothing to change.").items == [])
        #expect(TaskReview.parse("**Nothing to change**").items == [])
    }

    @Test func anAnswerThatIsntTheListIsShownAsIs() {
        let prose = "The changes look mostly fine, but the header could be tidier."
        #expect(TaskReview.parse(prose).items == nil)
        #expect(TaskReview.parse(prose).raw == prose)
        // A list with a sentence around it doesn't fit the shape either.
        let mixed = "Here is what I found:\n1. a.ts: one\n2. b.ts: two"
        #expect(TaskReview.parse(mixed).items == nil)
        #expect(TaskReview.parse(mixed).raw == mixed)
    }

    @Test func theBriefAsksForTheShapeTheParserReads() {
        let brief = TaskReview.brief(title: "Tidy the header", tasks: ["make the header bigger"], files: ["src/App.tsx"], diff: nil)
        #expect(brief.contains("1. <file>:"))
        #expect(brief.contains(TaskReview.nothingLine))
        #expect(brief.contains("Do not change any files."))
    }

    /// Opened → checked → merge: where the review is, without GitHub.
    @Test func theCardSaysWhichStepItsOn() {
        let url = URL(string: "https://github.com/o/r/pull/12")!
        var state = TaskReview.State(number: 12, url: url, title: "hcr: 2 changes")
        let checking = TaskReview.steps(state, reviewerFinished: false, standing: .ready)
        #expect(checking.map(\.state) == [.done, .now, .later], "Merge waits for the Reviewer")
        state.items = []
        #expect(TaskReview.steps(state, reviewerFinished: true, standing: .ready).map(\.state) == [.done, .done, .now])
        #expect(TaskReview.steps(state, reviewerFinished: true, standing: .checking).map(\.state) == [.done, .done, .later])
        let mine = TaskReview.State(number: 12, url: url, title: "t", mine: true)
        #expect(TaskReview.steps(mine, reviewerFinished: false, standing: .ready).map(\.state) == [.done, .now, .now])
    }

    @Test func mergeStateReadsAsOneOutcome() {
        func s(_ state: String = "open", merged: Bool = false, mergeable: Bool? = true, ms: String?, can: Bool = true) -> TaskReview.Standing {
            TaskReview.standing(state: state, merged: merged, mergeable: mergeable, mergeableState: ms, mergeSHA: "abc", canMerge: can)
        }
        #expect(s(ms: "clean") == .ready)
        #expect(s(ms: "unstable") == .ready)
        #expect(s(ms: "clean", can: false) == .notAllowed)
        #expect(s(ms: "blocked") == .needsReview)
        #expect(s(mergeable: nil, ms: "dirty") == .conflict)
        #expect(s(ms: "behind") == .behind)
        #expect(s(mergeable: nil, ms: "unknown") == .checking)
        #expect(s("closed", merged: true, ms: nil) == .merged("abc"))
        #expect(s("closed", ms: nil) == .closed)
        // Merge shows only for .ready: every other outcome says why in a sentence.
        for other: TaskReview.Standing in [.checking, .needsReview, .conflict, .behind, .notAllowed, .closed] {
            #expect(other.sentence != nil)
        }
        #expect(TaskReview.Standing.ready.sentence == nil)
    }

    @Test func theCardNeverSaysGitWords() {
        let lines = [TaskReview.Standing.checking, .needsReview, .conflict, .behind, .notAllowed, .closed].compactMap(\.sentence)
            + [TaskReview.nextTaskLine(fromMain: true), TaskReview.nextTaskLine(fromMain: false)]
        for line in lines {
            for word in ["branch", "worktree", "commit", "rebase"] {
                #expect(!line.lowercased().contains(word), "\(line)")
            }
        }
    }

    @Test func aNewTaskAsksForAFreshWorkCopy() {
        #expect(RunCoordinator.workspaceKey(botName: "Bakery site", task: nil) == "Bakery site")
        #expect(RunCoordinator.workspaceKey(botName: "Bakery site", task: 1) == "Bakery site")
        #expect(RunCoordinator.workspaceKey(botName: "Bakery site", task: 2) == "Bakery site 2")
        // The task number survives darkmux's name limit.
        let long = String(repeating: "x", count: 40)
        let key = RunCoordinator.workspaceKey(botName: long, task: 3)
        #expect(key.hasSuffix(" 3"))
        #expect(key.count <= DarkmuxClient.WorkspaceBody.botNameLimit)
    }
}
