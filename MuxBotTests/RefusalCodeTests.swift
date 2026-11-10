import Foundation
import Testing
@testable import MuxBot

/// darkmux #3513's two refusals, each in one plain sentence; its own words
/// stay behind Show details.
@MainActor
struct RefusalCodeTests {
    static let noOwnBranch = DarkmuxClient.ClientError(
        message: "the workspace isn't on a mux/ branch of its own; the next run moves it to one", status: 409, code: "no_own_branch")
    static let branchFailed = DarkmuxClient.ClientError(
        message: "couldn't create branch mux/site-3f2a: fatal: cannot lock ref 'refs/heads/mux/site-3f2a'", status: 422, code: "branch_failed")

    @Test func noOwnBranchSaysTheNextRunMovesIt() {
        let line = DarkmuxPlain.sentence(Self.noOwnBranch)
        #expect(line == "This work copy isn't on its own Mux Bot branch yet. Start a run and darkmux moves it there, then try again.")
        #expect(PreviewFailureTests.isPlain(line))
        #expect(!line.contains("mux/") && !line.contains("409"))
    }

    @Test func branchFailedSaysGitsReasonIsInDetails() {
        let line = DarkmuxPlain.sentence(Self.branchFailed)
        #expect(line == "darkmux couldn't make this bot's branch in the work copy. Show details has git's reason.")
        #expect(!line.contains("refs/") && !line.contains("422"))
        #expect(DarkmuxPlain.details(Self.branchFailed)?.contains("cannot lock ref") == true)
    }

    /// A run that can't start because git couldn't branch says why, not
    /// just "Couldn't start".
    @Test func aRunThatCouldntBranchSaysSo() {
        guard case .fail(let reason, let details) = RunCoordinator.startFailure(Self.branchFailed) else {
            Issue.record("not a failure"); return
        }
        #expect(reason == DarkmuxPlain.sentence(Self.branchFailed))
        #expect(details?.contains("cannot lock ref") == true)
    }

    /// Put it on GitHub reads darkmux's changes too: its refusal is plain there.
    @Test func putOnGitHubSaysItPlainly() {
        #expect(PutOnGitHub.problem(Self.noOwnBranch) == DarkmuxPlain.sentence(Self.noOwnBranch))
        #expect(PutOnGitHub.problem(GitHubRepoMaker.Failure.plain("It's already being put on GitHub.")) == "It's already being put on GitHub.")
    }
}
