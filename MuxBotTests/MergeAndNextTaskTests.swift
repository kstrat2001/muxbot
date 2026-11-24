import Foundation
import Testing
@testable import MuxBot

/// #144 step 4: Merge is pinned to the head darkmux reports for the work
/// copy; after a merge the work copy moves onto the next task from the
/// merged main (darkmux's `new_task`, #3684); and Bring in changes brings a
/// main version that moved into the task through darkmux (`merge_main`).
@Suite(.serialized) @MainActor
struct MergeAndNextTaskTests {
    private let repo = "kain/site"

    private func status(head: String = "abc", ahead: Int = 0, pending: Int = 1) -> DarkmuxClient.GitStatus {
        .init(branch: "mux/site-1", head: head, origin: "github.com/kain/site", defaultBranch: "main", base: "b0", pending: pending,
              upstream: .init(ref: "origin/mux/site-1", head: head), ahead: ahead, behind: 0, behindMain: 0, dirty: false, busy: nil)
    }

    private func setUp() -> (BotStore, Bot, RunCoordinator, GitHubAuth) {
        GitHubStub.reset()
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        store.addResource(.repo, "https://github.com/\(repo)", to: bot)
        LocalBotState.shared.update(bot.id) {
            $0.review = TaskReview.State(number: 7, url: URL(string: "https://github.com/\(repo)/pull/7")!, title: "Warmer")
        }
        let runs = RunCoordinator()
        runs.githubSession = GitHubStub.session
        runs.githubToken = { "ghu_abc" }
        let current = status()
        runs.gitStatusSource = { _ in current }
        let keychain = MemoryKeychain(); keychain.items[GitHubAuth.tokenKey] = "ghu_abc"
        let github = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, sleep: { _ in })
        return (store, bot, runs, github)
    }

    private func pull(head: String, state: String = "clean") {
        GitHubStub.on("GET /repos/\(repo)/pulls/7", 200,
                      #"{"state":"open","merged":false,"mergeable":true,"mergeable_state":"\#(state)","head":{"sha":"\#(head)","ref":"mux/site-1"}}"#)
        GitHubStub.on("GET /repos/\(repo)", 200, #"{"permissions":{"push":true}}"#)
    }

    private func said(_ store: BotStore, _ bot: Bot) -> [String] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
    }

    /// darkmux's head and GitHub's differ: nothing merges, and the sha a
    /// merge sends is darkmux's, never only GitHub's.
    @Test func mergeIsPinnedToTheHeadDarkmuxReports() async {
        let (store, bot, runs, github) = setUp()
        runs.gitNewTasker = { _, _, _ in .init(moved: true, branch: "mux/site-2", head: "n1", carried: 0) }
        runs.gitFetcher = { _, _ in self.status() }
        runs.gitStatusSource = { _ in self.status(head: "local9") }
        pull(head: "abc")
        GitHubStub.on("PUT /repos/\(repo)/pulls/7/merge", 200, #"{"sha":"m1","merged":true}"#)
        await runs.mergeReview(bot, store: store, github: github)
        var merges = GitHubStub.seen.filter { $0.method == "PUT" && $0.path.hasSuffix("/merge") }
        #expect(merges.isEmpty, "GitHub's head isn't the work copy's")
        runs.gitStatusSource = { _ in self.status(head: "abc") }
        pull(head: "abc")
        await runs.mergeReview(bot, store: store, github: github)
        merges = GitHubStub.seen.filter { $0.method == "PUT" && $0.path.hasSuffix("/merge") }
        #expect(merges.first?.body?["sha"] as? String == "abc")
    }

    @Test func afterAMergeTheWorkCopyMovesOntoTheNextTask() async {
        let (store, bot, runs, github) = setUp()
        pull(head: "abc")
        await runs.refreshReview(bot, store: store, github: github)
        let steps = Recorder()
        runs.gitFetcher = { workspace, github in steps.add("fetch \(workspace) \(github ?? "-")"); return self.status() }
        runs.gitNewTasker = { workspace, head, sha in steps.add("new_task \(workspace) \(head) \(sha)"); return .init(moved: true, branch: "mux/site-2", head: "n1", carried: 0) }
        runs.workspaceMaker = { _ in Issue.record("no new work copy"); throw CancellationError() }
        runs.gitStatusSource = { _ in self.status(head: "n1", pending: 0) }
        await runs.afterMerge(bot, mergeSHA: "m1", store: store)
        #expect(steps.values == ["fetch site-1 ghu_abc", "new_task site-1 abc m1"], "\(steps.values)")
        #expect(bot.workspaceName == "site-1", "the work copy stays")
        #expect(runs.taskState(bot, store: store) == .clean, "darkmux's own status reads clean, on every device")
        #expect(said(store, bot).contains(TaskReview.nextTaskLine))
    }

    @Test func theNextTaskWaitsForTheMergeToBeFetchedAndForARunToEnd() async {
        let (store, bot, runs, github) = setUp()
        runs.runWaitInterval = .milliseconds(10)
        runs.busyRetryInterval = .milliseconds(10)
        pull(head: "abc")
        await runs.refreshReview(bot, store: store, github: github)
        runs.gitFetcher = { _, _ in self.status() }
        let tries = Counter()
        runs.gitNewTasker = { _, _, _ in
            tries.add()
            switch tries.count {
            case 1: throw DarkmuxClient.ClientError(message: "fetch first", status: 409, code: "stale_main")
            case 2: throw DarkmuxClient.ClientError(message: "run w-3 is working", status: 409, code: "work_copy_busy", holder: "run")
            default: return .init(moved: true, branch: "mux/site-2", head: "n1", carried: 1)
            }
        }
        await runs.afterMerge(bot, mergeSHA: "m1", store: store)
        #expect(tries.count == 3, "after the fetch, and after the run, it moves")
    }

    @Test func aMergeSeenTwiceEndsTheTaskOnce() async {
        let (store, bot, runs, github) = setUp()
        pull(head: "abc")
        await runs.refreshReview(bot, store: store, github: github)
        runs.gitFetcher = { _, _ in try? await Task.sleep(for: .milliseconds(50)); return self.status() }
        let moves = Counter()
        runs.gitNewTasker = { _, _, _ in moves.add(); return .init(moved: true, branch: "mux/site-2", head: "n1", carried: 0) }
        let one = Task { await runs.afterMerge(bot, mergeSHA: "m1", store: store) }
        let two = Task { await runs.afterMerge(bot, mergeSHA: "m1", store: store) }
        await one.value
        await two.value
        #expect(moves.count == 1)
        #expect(said(store, bot).filter { $0 == TaskReview.nextTaskLine }.count == 1)
    }

    @Test func withoutNewTaskAFreshWorkCopyIsMade() async {
        let (store, bot, runs, github) = setUp()
        pull(head: "abc")
        await runs.refreshReview(bot, store: store, github: github)
        runs.capabilitiesSource = { ["git_route"] }
        var asked: DarkmuxClient.WorkspaceBody?
        runs.workspaceMaker = { body in asked = body; return DarkmuxClient.Workspace(workspace: "site 2", branch: "mux/site-9", created: true) }
        await runs.afterMerge(bot, mergeSHA: "m1", store: store)
        #expect(asked != nil, "a fresh work copy from the main version")
        #expect(bot.workspaceName == "site 2")
    }

    @Test func bringInChangesMergesTheMovedMainAndSendsIt() async {
        let (store, bot, runs, github) = setUp()
        pull(head: "abc", state: "behind")
        await runs.refreshReview(bot, store: store, github: github)
        #expect(runs.taskState(bot, store: store) == .mainMoved)
        let steps = Recorder()
        runs.gitFetcher = { _, _ in steps.add("fetch"); return self.status() }
        runs.gitMerger = { _ in steps.add("merge"); return .init(head: "def", upToDate: false, fastForward: false) }
        runs.gitStatusSource = { _ in self.status(head: "def", ahead: 1) }
        runs.gitPusher = { _, _, _ in steps.add("push"); return .init(branch: "mux/site-1", head: "def", remote: "github.com/kain/site", addedOrigin: false) }
        await runs.bringInChanges(bot, store: store, github: github)
        #expect(steps.values == ["fetch", "merge", "push"], "\(steps.values)")
        #expect(said(store, bot).contains { $0.contains("Brought in the project's latest version") })
    }

    /// Unsent work goes to GitHub on its own when darkmux's status shows it,
    /// at most once a minute.
    @Test func unsentWorkIsSentOnItsOwnOnceAMinute() async {
        let (store, bot, runs, _) = setUp()
        runs.gitStatusSource = { _ in self.status(head: "def", ahead: 1) }
        let pushes = Counter()
        runs.gitPusher = { _, _, _ in pushes.add(); return .init(branch: "mux/site-1", head: "def", remote: "github.com/kain/site", addedOrigin: false) }
        await runs.refreshTaskStatus(bot, store: store)
        for _ in 0..<200 where pushes.count == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(pushes.count == 1)
        await runs.refreshTaskStatus(bot, store: store)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(pushes.count == 1, "not again within the minute")
    }

    @Test func alreadyUpToDateSaysSoAndSendsNothing() async {
        let (store, bot, runs, github) = setUp()
        pull(head: "abc", state: "behind")
        await runs.refreshReview(bot, store: store, github: github)
        runs.gitFetcher = { _, _ in self.status() }
        runs.gitMerger = { _ in .init(head: "abc", upToDate: true, fastForward: false) }
        runs.gitPusher = { _, _, _ in Issue.record("nothing pushed"); throw CancellationError() }
        await runs.bringInChanges(bot, store: store, github: github)
        #expect(said(store, bot).last == "This task already has the project's latest version.")
    }

    @Test func aConflictBringsInNothingAndSaysSoPlainly() async {
        let (store, bot, runs, github) = setUp()
        pull(head: "abc", state: "behind")
        await runs.refreshReview(bot, store: store, github: github)
        runs.gitFetcher = { _, _ in self.status() }
        runs.gitMerger = { _ in throw DarkmuxClient.ClientError(message: "conflicts", status: 409, code: "merge_conflict", paths: ["index.html"]) }
        runs.gitPusher = { _, _, _ in Issue.record("nothing pushed"); throw CancellationError() }
        await runs.bringInChanges(bot, store: store, github: github)
        let last = said(store, bot).last ?? ""
        #expect(last.contains("nothing was brought in"), "\(last)")
        #expect(!last.contains("index.html") && !last.lowercased().contains("branch"), "plain: \(last)")
    }
}
