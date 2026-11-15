import Foundation
import Testing
@testable import MuxBot

/// The app says "Merged" only when GitHub confirms it, and never merges a
/// pull request GitHub says was closed.
@Suite(.serialized) @MainActor
struct MergeConfirmedTests {
    private let review = GitHubReview(session: GitHubStub.session, token: "ghu_abc")

    @Test func aConfirmedMergeReturnsItsCommit() async throws {
        GitHubStub.reset()
        GitHubStub.on("PUT /repos/kstrat2001/hcr/pulls/13/merge", 200, #"{"sha":"c560","merged":true,"message":"Pull Request successfully merged"}"#)
        #expect(try await review.merge(repo: "kstrat2001/hcr", number: 13, title: "Tweak") == "c560")
    }

    @Test func anUnconfirmedMergeIsNotMerged() async {
        GitHubStub.reset()
        GitHubStub.on("PUT /repos/kstrat2001/hcr/pulls/13/merge", 200, #"{"sha":"c560"}"#)
        await #expect(throws: GitHubPR.Failure.self) {
            _ = try await review.merge(repo: "kstrat2001/hcr", number: 13, title: "Tweak")
        }
    }

    @Test func aClosedPullRequestIsClosed() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kstrat2001/hcr/pulls/13", 200, #"{"state":"closed","merged":false,"mergeable":true,"mergeable_state":"clean"}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr", 200, #"{"permissions":{"push":true}}"#)
        #expect(try await review.standing(repo: "kstrat2001/hcr", number: 13) == .closed)
    }
}
