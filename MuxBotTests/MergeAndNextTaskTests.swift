import Foundation
import Testing
@testable import MuxBot

/// #144 step 4: Merge is pinned to the head darkmux reports for the work
/// copy; after a merge the next run starts the next task fresh from the
/// project's main version (darkmux #3684); and Bring in changes brings a
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

    @Test func mergeIsPinnedToTheHeadDarkmuxReports() async {
        let (store, bot, runs, github) = setUp()
        runs.gitFetcher = { _, _ in self.status() }
        pull(head: "abc")
        GitHubStub.on("PUT /repos/\(repo)/pulls/7/merge", 200, #"{"sha":"m1","merged":true}"#)
        await runs.mergeReview(bot, store: store, github: github)
        let merges = GitHubStub.seen.filter { $0.method == "PUT" && $0.path.hasSuffix("/merge") }
        #expect(merges.first?.body?["sha"] as? String == "abc")
    }

    @Test func afterAMergeTheNextRunStartsTheNextTaskFresh() async {
        let (store, bot, runs, _) = setUp()
        let fetched = Recorder()
        runs.gitFetcher = { workspace, github in fetched.add("\(workspace) \(github ?? "-")"); return self.status(pending: 0) }
        runs.workspaceMaker = { _ in Issue.record("no new work copy"); throw CancellationError() }
        await runs.afterMerge(bot, mergeSHA: "m1", store: store)
        #expect(fetched.values == ["site-1 ghu_abc"], "the merged main is fetched")
        #expect(bot.workspaceName == "site-1", "the work copy stays")
        #expect(LocalBotState.shared[bot.id]?.startFresh == true)
        #expect(runs.taskState(bot, store: store) == .clean, "nothing in the next task yet")
        #expect(said(store, bot).contains(TaskReview.nextTaskLine(fromMain: true)))
    }

    @Test func theFreshFlagGoesWithTheFirstRunOnlyAndNeverWithATweak() async {
        let (store, bot, runs, _) = setUp()
        LocalBotState.shared.update(bot.id) { $0.review = nil; $0.startFresh = true }
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-fresh-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        runs.deviceRuns = true
        runs.useOnDeviceModel = false
        runs.profileSource = { [] }
        runs.capabilitiesSource = { ["fresh_branch"] }
        runs.workSubmitter = { _, _, _, _, _ in ("w-1", nil) }
        runs.workStatusFetcher = { _ in try JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(#"{"status":"running"}"#.utf8)) }
        let first = store.proposeRun(task: "Next thing", crew: .coder, on: bot)
        runs.decide(.approve, on: first, store: store)
        for _ in 0..<100 where first.darkmuxWorkId == nil { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(runs.submittedFresh.contains(first.id), "the next task's first run starts fresh")
        #expect(LocalBotState.shared[bot.id]?.startFresh == nil, "only once")
        first.phase = .canceled
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
