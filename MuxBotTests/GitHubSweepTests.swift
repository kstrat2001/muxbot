import Foundation
import Testing
@testable import MuxBot

/// Sweep batch 6a: GitHub steps fail plainly and recover. Every GitHub call
/// is stubbed (GitHubStub); no network.
@Suite(.serialized) @MainActor
struct GitHubSweepTests {
    static let template = OwnRepoTests.template
    private func maker() -> GitHubRepoMaker { GitHubRepoMaker(session: GitHubStub.session, token: "ghu_abc") }
    private let treeKey = "GET /repos/kstrat2001/muxbot-template-book/git/trees/e044900cd94d086c841616b05ed63638aa402be4"

    private func stubFill(_ created: String) {
        GitHubStub.on(treeKey, 200, #"{"tree":[{"path":"book.json","mode":"100644","type":"blob","sha":"aaa"}],"truncated":false}"#)
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book/git/blobs/aaa", 200, #"{"content":"e30K","encoding":"base64"}"#)
        GitHubStub.on("POST /repos/\(created)/git/blobs", 201, #"{"sha":"n1"}"#)
        GitHubStub.on("POST /repos/\(created)/git/trees", 201, #"{"sha":"t1"}"#)
        GitHubStub.on("GET /repos/\(created)/git/ref/heads/main", 200, #"{"object":{"sha":"init0"}}"#)
        GitHubStub.on("POST /repos/\(created)/git/commits", 201, #"{"sha":"start1"}"#)
        GitHubStub.on("PATCH /repos/\(created)/git/refs/heads/main", 200, #"{"ref":"refs/heads/main"}"#)
    }

    // 1: a template that can't be copied makes no repo.

    @Test func aTemplateThatCantBeCopiedMakesNoRepo() async {
        GitHubStub.reset()
        GitHubStub.on(treeKey, 200, #"{"tree":[{"path":"vendor/lib","mode":"160000","type":"commit","sha":"sub1"}],"truncated":false}"#)
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides","html_url":"https://github.com/kain/tides","default_branch":"main"}"#)
        do {
            _ = try await maker().make(name: "tides", isPrivate: true, description: "", from: Self.template)
            Issue.record("expected a refusal")
        } catch GitHubRepoMaker.Failure.template {
        } catch { Issue.record("\(error)") }
        #expect(!GitHubStub.seen.contains { $0.method == "POST" && $0.path == "/user/repos" }, "no empty repo left behind")
    }

    // 2: the description, and GitHub's own reason.

    @Test func theDescriptionIsOneShortLine() {
        let long = "A site for our event.\n\nIt has a schedule, a map and " + String(repeating: "lots of details ", count: 40)
        let line = GitHubRepoMaker.describe(long)
        #expect(!line.contains("\n"))
        #expect(line.count <= 350)
        #expect(line.hasPrefix("A site for our event. It has"))
        #expect(line.hasSuffix("\u{2026}") && !line.hasSuffix(" \u{2026}"), "cut at a word")
        #expect(GitHubRepoMaker.describe("  A short\none ") == "A short one")
    }

    @Test func githubsOwnReasonIsSaid() async {
        GitHubStub.reset()
        stubFill("kain/tides")
        GitHubStub.on("POST /user/repos", 422, #"{"message":"Repository creation failed.","errors":[{"message":"description is too long (maximum is 350 characters)"}]}"#)
        do {
            _ = try await maker().make(name: "tides", isPrivate: true, description: "", from: Self.template)
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription.contains("description is too long"), "\(error.localizedDescription)")
        }
    }

    // 3: a name GitHub says is taken moves on.

    @Test func aNameGitHubSaysIsTakenMovesToTheNext() async throws {
        GitHubStub.reset()
        stubFill("kain/tides-2")
        GitHubStub.on("POST /user/repos", 422, #"{"message":"Repository creation failed.","errors":[{"message":"name already exists on this account"}]}"#)
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides-2","html_url":"https://github.com/kain/tides-2","default_branch":"main"}"#)
        let made = try await maker().make(name: "tides", isPrivate: true, description: "", from: Self.template)
        #expect(made.repo == "kain/tides-2")
        let names = GitHubStub.seen.filter { $0.method == "POST" && $0.path == "/user/repos" }.compactMap { $0.body?["name"] as? String }
        #expect(names == ["tides", "tides-2"])
    }

    // 4: an expired sign-in.

    @Test func anExpiredTokenIsRefreshedOnce() async throws {
        GitHubStub.reset()
        let keychain = MemoryKeychain()
        keychain.items[GitHubAuth.tokenKey] = "old"
        keychain.items[GitHubAuth.refreshKey] = "r1"
        let auth = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, sleep: { _ in })
        GitHubStub.on("POST /login/oauth/access_token", 200, #"{"access_token":"new","refresh_token":"r2"}"#)
        #expect(await auth.refresh() == "new")
        #expect(auth.token == "new")
        #expect(keychain.items[GitHubAuth.refreshKey] == "r2")
    }

    @Test func aRefreshThatFailsSignsOutPlainly() async {
        GitHubStub.reset()
        let keychain = MemoryKeychain()
        keychain.items[GitHubAuth.tokenKey] = "old"
        keychain.items[GitHubAuth.refreshKey] = "r1"
        let auth = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, sleep: { _ in })
        GitHubStub.on("POST /login/oauth/access_token", 200, #"{"error":"bad_refresh_token"}"#)
        #expect(await auth.refresh() == nil)
        #expect(auth.token == nil)
        #expect(auth.state == .failed(GitHubAuth.expiredMessage))
        #expect(GitHubAuth.expiredMessage == "Your GitHub sign-in expired. Sign in again.")
    }

    @Test func aWriteThatGets401RetriesWithTheRefreshedToken() async throws {
        GitHubStub.reset()
        GitHubSession.refresh = { .token("fresh") }
        defer { GitHubSession.refresh = nil }
        GitHubStub.on("GET /user", 401, #"{"message":"Bad credentials"}"#)
        GitHubStub.on("GET /user", 200, #"{"login":"kain"}"#)
        #expect(try await maker().login() == "kain")
        #expect(GitHubStub.seen.last?.auth == "Bearer fresh")
    }

    @Test func signInKeepsTheRefreshToken() async {
        GitHubStub.reset()
        GitHubStub.on("POST /login/device/code", 200, #"{"device_code":"dc1","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
        GitHubStub.on("POST /login/oauth/access_token", 200, #"{"access_token":"ghu_abc","refresh_token":"ghr_1","token_type":"bearer"}"#)
        GitHubStub.on("GET /user", 200, #"{"login":"kain"}"#)
        let keychain = MemoryKeychain()
        let auth = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, sleep: { _ in })
        await auth.signIn()
        #expect(keychain.items[GitHubAuth.refreshKey] == "ghr_1")
        auth.signOut()
        #expect(keychain.items[GitHubAuth.refreshKey] == nil, "signing out forgets it too")
    }

    @Test func settingsThatGets401SignsOutPlainly() async {
        GitHubStub.reset()
        let keychain = MemoryKeychain()
        keychain.items[GitHubAuth.tokenKey] = "old"
        let auth = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, sleep: { _ in })
        GitHubStub.on("GET /user", 401, #"{"message":"Bad credentials"}"#)
        await auth.loadUser()
        #expect(auth.state == .failed(GitHubAuth.expiredMessage), "no longer 'signed in' with a dead token")
        #expect(auth.token == nil)
    }

    @Test func a401ThatCantBeRenewedSaysTheSignInExpired() async {
        GitHubStub.reset()
        GitHubSession.refresh = { .expired }
        defer { GitHubSession.refresh = nil }
        GitHubStub.on("GET /user", 401, #"{"message":"Bad credentials"}"#)
        do {
            _ = try await maker().login()
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription == "Your GitHub sign-in expired. Sign in again.")
        }
    }

    @Test func noStatusCodeLeadsAMessage() async {
        GitHubStub.reset()
        stubFill("kain/tides")
        GitHubStub.on("POST /user/repos", 500, #"{"message":"Server Error"}"#)
        do {
            _ = try await maker().make(name: "tides", isPrivate: true, description: "", from: Self.template)
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription == "GitHub said: Server Error")
        }
    }

    @Test func installedButRefusedSaysTheRealProblem() {
        let installed = RunCoordinator.cantWriteText("kain/site", .installed)
        #expect(installed.contains("is installed on kain/site"))
        #expect(!installed.contains("Install Mux Bot on"))
        let missing = RunCoordinator.cantWriteText("kain/site", .notInstalled(URL(string: "https://github.com/apps/mux-bot/installations/new")!))
        #expect(missing.contains("https://github.com/apps/mux-bot/installations/new"))
    }

    // 8: Open PR's message when the App is installed.

    @Test func aMissingBaseCommitIsNotAnInstallProblem() async {
        GitHubStub.reset()
        let gh = GitHubPR(session: GitHubStub.session, token: "t", local: LocalBotState(fileURL: nil))
        let changes = DarkmuxClient.Changes(base: "abc1234", baseBranch: "main", head: "h1", branch: "mux/site", files: [])
        GitHubStub.on("GET /repos/kain/site/git/ref/heads/mux/site", 404, #"{"message":"Not Found"}"#)
        GitHubStub.on("GET /repos/kain/site/git/commits/abc1234", 404, #"{"message":"Not Found"}"#)
        do {
            _ = try await gh.push(changes, repo: "kain/site", message: "m", bot: UUID())
            Issue.record("expected a refusal")
        } catch GitHubPR.Failure.baseMissing(let commit) {
            #expect(commit == "abc1234")
        } catch { Issue.record("\(error)") }
    }
}

/// The run-side GitHub steps: pushes in order, a moved branch, Put it on GitHub.
@Suite(.serialized) @MainActor
struct GitHubRunSweepTests {
    private func setUp() -> (BotStore, Bot, RunCoordinator) {
        let store = TestStore.fresh()
        let bot = store.add(name: "Tides", instructions: "")
        bot.workspaceName = "tides-1"
        bot.useCaseId = "book"
        let runs = RunCoordinator()
        runs.githubToken = { "ghu_abc" }
        runs.changesFetcher = { _ in DarkmuxClient.Changes(base: "b0", baseBranch: "main", head: "h1", branch: "mux/tides",
                                                           files: [.init(path: "a.md", mode: nil, content: "eA==", deleted: nil)]) }
        return (store, bot, runs)
    }

    // 7: one push at a time per bot; a moved branch gets a new one.

    @Test func pushesForABotNeverOverlap() async {
        let (store, bot, runs) = setUp()
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        bot.githubStart = GitHubPR.Start(commit: "s1", branch: "main", head: "mux/tides")
        let pushes = Overlap()
        runs.prPusher = { _, _, _, _, _ in
            pushes.begin()
            try await Task.sleep(for: .milliseconds(80))
            pushes.end()
            return GitHubPR.Pushed(commit: "c")
        }
        let a = Task { await runs.backUp(bot, store: store) }
        let b = Task { await runs.backUp(bot, store: store) }
        await a.value
        await b.value
        #expect(pushes.count == 2)
        #expect(pushes.most == 1, "the second push waits for the first")
    }

    @Test func aBranchThatMovedGetsANewOneInsteadOfADeadEnd() async {
        let (store, bot, runs) = setUp()
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        bot.githubStart = GitHubPR.Start(commit: "s1", branch: "main", head: "mux/tides")
        let heads = Recorder()
        runs.prPusher = { _, _, _, _, start in
            heads.add(start?.head ?? "")
            if start?.head == "mux/tides" { throw GitHubPR.Failure.branchMoved("mux/tides") }
            return GitHubPR.Pushed(commit: "c")
        }
        await runs.backUp(bot, store: store)
        #expect(heads.values == ["mux/tides", "mux/tides-2"])
        #expect(bot.githubStart?.head == "mux/tides-2")
        let said = (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
        #expect(said.contains { $0.contains("mux/tides-2") && !$0.lowercased().contains("pull their") }, "\(said)")
    }

    @Test func noBackupBuildsOnTheTemplateWhileAPutIsUnfinished() async {
        let (store, bot, runs) = setUp()
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        bot.githubStart = GitHubPR.Start(commit: "s1", branch: "main", head: "mux/tides")
        LocalBotState.shared.update(bot.id) { $0.putPending = true }
        let pushes = Overlap()
        runs.prPusher = { _, _, _, _, _ in pushes.begin(); pushes.end(); return GitHubPR.Pushed(commit: "c") }
        await runs.backUp(bot, store: store)
        #expect(pushes.count == 0, "the work goes to the default branch first")
    }

    // 6 + 9: Put it on GitHub records the work commit and resumes.

    @Test func putOnGitHubResumesIntoTheRepoItMadeAndRecordsTheWorkCommit() async throws {
        let (store, bot, runs) = setUp()
        let old = store.proposeRun(task: "old work", crew: .coder, on: bot)
        store.apply(.approve, to: old)
        old.keptCommit = "k1"
        store.apply(.finish(summary: "done"), to: old)
        let made = GitHubRepoMaker.Made(repo: "kain/tides", url: URL(string: "https://github.com/kain/tides")!, defaultBranch: "main", startCommit: "s1")
        let pushes = Overlap()
        let push: PutOnGitHub.Push = { _, _, _, _, _ in
            pushes.begin(); pushes.end()
            if pushes.count == 1 { throw GitHubPR.Failure.github("status 502") }
            return GitHubPR.Pushed(commit: "work1")
        }
        do {
            _ = try await PutOnGitHub.run(bot, isPublic: false, make: { made }, push: push, store: store, runs: runs)
            Issue.record("the first push fails")
        } catch {
            #expect(!error.localizedDescription.contains("It's empty"), "\(error.localizedDescription)")
            #expect(error.localizedDescription.contains("kain/tides"))
        }
        #expect(bot.repoSlugs == ["kain/tides"], "the repo is recorded as soon as it's made")
        #expect(PutOnGitHub.canResume(bot), "Put resumes the push into it")
        let makes = Overlap()
        _ = try await PutOnGitHub.run(bot, isPublic: false, make: { makes.begin(); makes.end(); return made }, push: push, store: store, runs: runs)
        #expect(makes.count == 0, "no second repo")
        #expect(!PutOnGitHub.canResume(bot))
        // Sweep 2 #3: the template's start stays the tree base; Put's commit
        // is the parent a new mux/<bot> goes on.
        #expect(bot.githubStart?.commit == "s1")
        #expect(bot.githubStart?.parent == "work1", "mux/<bot> builds on the pushed work")
        #expect(runs.unshippedRuns(bot, store: store).isEmpty, "earlier work isn't offered again")
    }
}

/// Counts calls and the most running at once.
final class Overlap: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var most = 0
    private(set) var count = 0
    func begin() { lock.withLock { now += 1; count += 1; most = max(most, now) } }
    func end() { lock.withLock { now -= 1 } }
}
