import Foundation
import Testing
@testable import MuxBot

/// muxbot#144: the app's side of darkmux's git route and file route
/// (darkmux #3681, #3688), as they go over the wire. darkmux's own tests
/// pin its side; these pin the requests and replies the app reads.
@Suite(.serialized) @MainActor
struct DarkmuxGitWireTests {
    private var client: DarkmuxClient { DarkmuxClient(session: GitHubStub.session) }
    private let status = #"{"verb":"status","result":{"branch":"mux/site-1","head":"abc","origin":"github.com/kain/site","default_branch":"main","base":"b0","pending":2,"upstream":{"ref":"origin/mux/site-1","head":"abd"},"ahead":1,"behind":0,"behind_main":3,"dirty":false,"busy":{"holder":"git:push","work_id":null}}}"#

    private func sent(_ path: String) -> GitHubStub.Seen? { GitHubStub.seen.last { $0.path == path } }

    @Test func statusIsAVerbWithNoArgsAndItsResultIsRead() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /client/workspaces/site-1/git", 200, status)
        let s = try await client.gitStatus(token: "t", workspace: "site-1")
        let asked = try #require(sent("/client/workspaces/site-1/git"))
        #expect(asked.body?["verb"] as? String == "status")
        #expect((asked.body?["args"] as? [String: Any])?.isEmpty == true)
        #expect(asked.auth == "Bearer t")
        #expect(s.head == "abc" && s.pending == 2 && s.ahead == 1 && s.behindMain == 3 && s.defaultBranch == "main")
        #expect(s.upstream == .init(ref: "origin/mux/site-1", head: "abd"))
        #expect(s.busy?.holder == "git:push" && s.busy?.workId == nil)
        #expect(s.repo == "kain/site")
    }

    @Test func pushSendsTheTokenAndTheRepoOnlyWhenGiven() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /client/workspaces/site-1/git", 200, #"{"verb":"push","result":{"branch":"main","head":"abc","remote":"github.com/kain/site","added_origin":true}}"#)
        let pushed = try await client.gitPush(token: "t", workspace: "site-1", github: "ghu_x", repo: "kain/site")
        let args = sent("/client/workspaces/site-1/git")?.body?["args"] as? [String: String]
        #expect(sent("/client/workspaces/site-1/git")?.body?["verb"] as? String == "push")
        #expect(args == ["token": "ghu_x", "repo": "kain/site"])
        #expect(pushed.addedOrigin)
        GitHubStub.on("POST /client/workspaces/site-1/git", 200, #"{"verb":"push","result":{"branch":"mux/site-1","head":"abc","remote":"github.com/kain/site","added_origin":false}}"#)
        _ = try await client.gitPush(token: "t", workspace: "site-1", github: nil)
        #expect((sent("/client/workspaces/site-1/git")?.body?["args"] as? [String: String]) == [:], "no token, no repo")
    }

    @Test func fetchAndMergeMainAreTheirVerbs() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /client/workspaces/site-1/git", 200, status)
        _ = try await client.gitFetch(token: "t", workspace: "site-1", github: "ghu_x")
        #expect(sent("/client/workspaces/site-1/git")?.body?["verb"] as? String == "fetch")
        #expect((sent("/client/workspaces/site-1/git")?.body?["args"] as? [String: String]) == ["token": "ghu_x"])
        GitHubStub.on("POST /client/workspaces/site-1/git", 200, #"{"verb":"merge_main","result":{"head":"d","up_to_date":false,"fast_forward":true}}"#)
        let merged = try await client.gitMergeMain(token: "t", workspace: "site-1")
        #expect(sent("/client/workspaces/site-1/git")?.body?["verb"] as? String == "merge_main")
        #expect(merged.fastForward && !merged.upToDate)
    }

    @Test func aRefusalCarriesItsCodeHolderAndPaths() async {
        GitHubStub.reset()
        GitHubStub.on("POST /client/workspaces/site-1/git", 409, #"{"error":"`git push` is going in this work copy","code":"work_copy_busy","holder":"git:push"}"#)
        do {
            _ = try await client.gitPush(token: "t", workspace: "site-1", github: nil)
            Issue.record("expected a refusal")
        } catch let error as DarkmuxClient.ClientError {
            #expect(error.code == "work_copy_busy" && error.holder == "git:push" && error.status == 409)
            #expect(RunCoordinator.waitsFor(error), "a git holder clears on its own: wait")
        } catch { Issue.record("\(error)") }
        GitHubStub.on("POST /client/workspaces/site-1/git", 409, #"{"error":"conflicts","code":"merge_conflict","paths":["a.css","b.css"]}"#)
        do {
            _ = try await client.gitMergeMain(token: "t", workspace: "site-1")
        } catch let error as DarkmuxClient.ClientError {
            #expect(error.paths == ["a.css", "b.css"])
        } catch { Issue.record("\(error)") }
    }

    @Test func aRunHoldingTheCopyIsNoWait() {
        let run = DarkmuxClient.ClientError(message: "run w-1 is already working", status: 409, code: "work_copy_busy", holder: "run")
        #expect(!RunCoordinator.waitsFor(run), "a run can take long: said, not waited for")
        #expect(RunCoordinator.waitsFor(.init(message: "", status: 409, code: "conflict", holder: "edit")))
        #expect(!RunCoordinator.waitsFor(.init(message: "", status: 409, code: "conflict")))
    }

    @Test func anApprovedFileGoesAsItsPathAndBytes() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /client/workspaces/site-1/file", 200, #"{"path":".darkmux/preview.json","work_id":"w-1","commit":"abc1234","branch":"mux/site-1"}"#)
        let data = Data("{\"schema_version\":\"1.0\"}\n".utf8)
        let saved = try await client.addFile(token: "t", workspace: "site-1", path: ".darkmux/preview.json", data: data)
        let asked = try #require(sent("/client/workspaces/site-1/file"))
        #expect(asked.body?["path"] as? String == ".darkmux/preview.json")
        #expect(asked.body?["data"] as? String == data.base64EncodedString())
        #expect(saved.workId == "w-1")
    }
}

/// muxbot#144: a push waits while something quick holds the work copy,
/// renews a sign-in GitHub refused once, and the status's busy and offline
/// come from darkmux's latest answer.
@Suite(.serialized) @MainActor
struct GitSendWaitsAndRenewsTests {
    private func setUp() -> (BotStore, Bot, RunCoordinator) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        store.addResource(.repo, "https://github.com/kain/site", to: bot)
        let runs = RunCoordinator()
        runs.busyRetryInterval = .milliseconds(10)
        runs.githubToken = { "ghu_old" }
        runs.gitStatusSource = { _ in OwnRepoTests.status(origin: "github.com/kain/site") }
        return (store, bot, runs)
    }

    private let pushed = DarkmuxClient.GitPushed(branch: "mux/site-1", head: "h1", remote: "github.com/kain/site", addedOrigin: false)

    @Test func aPushWaitsWhileAnotherGitStepHoldsTheCopy() async throws {
        let (store, bot, runs) = setUp()
        let tries = Counter()
        runs.gitPusher = { [pushed] _, _, _ in
            tries.add()
            if tries.count < 3 { throw DarkmuxClient.ClientError(message: "busy", status: 409, code: "work_copy_busy", holder: "git:fetch") }
            return pushed
        }
        let result = try await runs.pushTask(bot, store: store, github: "ghu_old")
        #expect(result == pushed)
        #expect(tries.count == 3)
    }

    @Test func aRefusedSignInIsRenewedOnceAndTriedAgain() async throws {
        let (store, bot, runs) = setUp()
        GitHubSession.refresh = { .token("ghu_new") }
        defer { GitHubSession.refresh = nil }
        let tokens = Recorder()
        runs.gitPusher = { [pushed] _, github, _ in
            tokens.add(github ?? "-")
            if github == "ghu_old" { throw DarkmuxClient.ClientError(message: "refused", status: 502, code: "auth_failed") }
            return pushed
        }
        _ = try await runs.pushTask(bot, store: store, github: "ghu_old")
        #expect(tokens.values == ["ghu_old", "ghu_new"])
    }

    @Test func aSignInThatCantBeRenewedAsksForANewOne() async {
        let (store, bot, runs) = setUp()
        GitHubSession.refresh = { .expired }
        defer { GitHubSession.refresh = nil }
        runs.gitPusher = { _, _, _ in throw DarkmuxClient.ClientError(message: "refused", status: 502, code: "auth_failed") }
        await #expect(throws: RunCoordinator.SendRefused(sentence: GitHubAuth.expiredMessage)) {
            _ = try await runs.pushTask(bot, store: store, github: "ghu_old")
        }
    }

    @Test func offlineAndBusyComeFromTheLatestAnswer() async {
        let (store, bot, runs) = setUp()
        _ = store
        let answer = Counter()
        runs.gitStatusSource = { _ in
            switch answer.count {
            case 0: throw URLError(.cannotConnectToHost)
            case 1: throw DarkmuxClient.ClientError(message: "bad gateway", status: 502)
            case 2: return .init(branch: "b", head: "h", origin: "github.com/kain/site", defaultBranch: "main", base: "b0", pending: 1,
                                 upstream: nil, ahead: 1, behind: nil, behindMain: 0, dirty: false, busy: .init(holder: "run", workId: "w-1"))
            default: return OwnRepoTests.status(origin: "github.com/kain/site")
            }
        }
        await runs.refreshTaskStatus(bot)
        #expect(runs.taskState(bot, store: store) == .offline)
        answer.add()
        await runs.refreshTaskStatus(bot)
        #expect(runs.taskState(bot, store: store) == .offline, "the tailnet entry's 502: no answer from darkmux")
        answer.add()
        await runs.refreshTaskStatus(bot)
        #expect(runs.taskState(bot, store: store) == .busy)
        answer.add()
        await runs.refreshTaskStatus(bot)
        #expect(runs.taskState(bot, store: store) == .changed, "busy and offline never stick")
    }

    @Test func aPendingPutIsNeverTakenForAnEarlierMuxBot() async {
        let (store, bot, runs) = setUp()
        bot.useCaseId = "book"
        let status = OwnRepoTests.status(origin: nil, ahead: nil)
        #expect(RunCoordinator.isFromAnEarlierMuxBot(bot, status: status))
        ModelSettingsStore.shared.setPendingRepo("kain/site", bot: bot.id)
        defer { ModelSettingsStore.shared.setPendingRepo(nil, bot: bot.id) }
        #expect(!RunCoordinator.isFromAnEarlierMuxBot(bot, status: status), "a Put still finishing")
        let existing = store.add(name: "folder", instructions: "")
        store.addResource(.repo, "https://github.com/kain/site", to: existing)
        #expect(!RunCoordinator.isFromAnEarlierMuxBot(existing, status: status), "only a project made from a template")
        _ = runs
    }
}
