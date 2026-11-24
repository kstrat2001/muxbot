import Foundation
import Testing
@testable import MuxBot

/// #144 steps 2 and 3: Merge runs the task's checks and merges at once,
/// pinned to the head GitHub has, which must be the head darkmux reports for
/// the work copy; anything in the way is said and nothing is merged.
@Suite(.serialized) @MainActor
struct TaskStateWiringTests {
    private let repo = "kain/site"

    private func setUp(sent: String?) -> (BotStore, Bot, RunCoordinator, GitHubAuth) {
        GitHubStub.reset()
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        store.addResource(.repo, "https://github.com/\(repo)", to: bot)
        LocalBotState.shared.update(bot.id) {
            $0.review = TaskReview.State(number: 7, url: URL(string: "https://github.com/\(repo)/pull/7")!, title: "Warmer")
        }
        let runs = RunCoordinator()
        // darkmux's status of the work copy (darkmux #3681): its head, and
        // GitHub's branch has it all.
        runs.gitStatusSource = { _ in
            try JSONDecoder().decode(DarkmuxClient.GitStatus.self, from: Data("""
                {"branch":"mux/site","head":\(sent.map { "\"\($0)\"" } ?? "null"),"origin":"github.com/kain/site","default_branch":"main",
                 "pending":\(sent == nil ? 0 : 1),"ahead":0,"dirty":false}
                """.utf8))
        }
        runs.githubSession = GitHubStub.session
        let keychain = MemoryKeychain(); keychain.items[GitHubAuth.tokenKey] = "ghu_abc"
        let github = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, sleep: { _ in })
        return (store, bot, runs, github)
    }

    private func pull(head: String, state: String = "clean") {
        GitHubStub.on("GET /repos/\(repo)/pulls/7", 200,
                      #"{"state":"open","merged":false,"mergeable":true,"mergeable_state":"\#(state)","head":{"sha":"\#(head)","ref":"mux/site"}}"#)
        GitHubStub.on("GET /repos/\(repo)", 200, #"{"permissions":{"push":true}}"#)
    }

    private var merges: [GitHubStub.Seen] { GitHubStub.seen.filter { $0.method == "PUT" && $0.path.hasSuffix("/merge") } }

    private func said(_ store: BotStore, _ bot: Bot) -> [String] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
    }

    @Test func mergeIsPinnedToTheHeadThatWasSent() async {
        let (store, bot, runs, github) = setUp(sent: "abc")
        pull(head: "abc")
        GitHubStub.on("PUT /repos/\(repo)/pulls/7/merge", 200, #"{"sha":"m1","merged":true}"#)
        await runs.mergeReview(bot, store: store, github: github)
        #expect(merges.count == 1)
        #expect(merges.first?.body?["sha"] as? String == "abc")
    }

    @Test func commitsSomeoneElsePushedAreNeverMergedUnseen() async {
        let (store, bot, runs, github) = setUp(sent: "abc")
        pull(head: "zzz")
        await runs.mergeReview(bot, store: store, github: github)
        #expect(merges.isEmpty)
        #expect(said(store, bot).contains { $0.contains("Someone changed this review on GitHub") })
    }

    @Test func aRunGoingMeansWaitAndSaySo() async {
        let (store, bot, runs, github) = setUp(sent: "abc")
        pull(head: "abc")
        let run = store.proposeRun(task: "Make it warm", crew: .coder, on: bot)
        run.phase = .running
        await runs.mergeReview(bot, store: store, github: github)
        #expect(merges.isEmpty)
        #expect(said(store, bot).contains { $0.contains("Wait for the change") })
        run.phase = .canceled
    }

    @Test func gitHubNotReadyIsSaidAndNothingMerges() async {
        let (store, bot, runs, github) = setUp(sent: "abc")
        pull(head: "abc", state: "dirty")
        await runs.mergeReview(bot, store: store, github: github)
        #expect(merges.isEmpty)
        #expect(said(store, bot).contains(TaskReview.Standing.conflict.sentence!))
    }

    @Test func theFactsComeFromGitHubAndDarkmux() async {
        let (store, bot, runs, github) = setUp(sent: "abc")
        pull(head: "abc")
        await runs.refreshReview(bot, store: store, github: github)
        #expect(runs.taskState(bot, store: store) == .inReview)
        #expect(runs.taskFacts(bot, store: store).review?.head == "abc")
    }

    @Test func aRefusedShelfActionSaysWhyAndDoesNothing() {
        let (store, bot, runs, _) = setUp(sent: nil)
        LocalBotState.shared.update(bot.id) { $0.review = nil }
        var did = false
        let went = runs.whenAllowed(.reviewAndMerge, bot, store: store) { did = true }
        #expect(!went && !did)
        #expect(said(store, bot).contains("There are no changes to review yet."))
    }
}
