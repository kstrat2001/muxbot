import Foundation
import Testing
@testable import MuxBot

/// Sweep batch 6a: GitHub steps fail plainly and recover. Every GitHub call
/// is stubbed (GitHubStub); no network.
@Suite(.serialized) @MainActor
struct GitHubSweepTests {
    static let template = OwnRepoTests.template
    private func maker() -> GitHubRepoMaker { GitHubRepoMaker(session: GitHubStub.session, token: "ghu_abc") }
    /// The new repo is empty: darkmux pushes the project's own history into
    /// it (darkmux #3681), so nothing is copied through GitHub's API.
    @Test func theNewRepoIsMadeEmpty() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides","html_url":"https://github.com/kain/tides"}"#)
        let made = try await maker().make(name: "tides", isPrivate: true, description: "")
        #expect(made.repo == "kain/tides")
        let asked = GitHubStub.seen.first { $0.method == "POST" && $0.path == "/user/repos" }
        #expect(asked?.body?["auto_init"] as? Bool == false)
        #expect(GitHubStub.seen.count == 1, "no blobs, trees or commits")
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
        GitHubStub.on("POST /user/repos", 422, #"{"message":"Repository creation failed.","errors":[{"message":"description is too long (maximum is 350 characters)"}]}"#)
        do {
            _ = try await maker().make(name: "tides", isPrivate: true, description: "")
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription.contains("description is too long"), "\(error.localizedDescription)")
        }
    }

    // 3: a name GitHub says is taken moves on.

    @Test func aNameGitHubSaysIsTakenMovesToTheNext() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /user/repos", 422, #"{"message":"Repository creation failed.","errors":[{"message":"name already exists on this account"}]}"#)
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides-2","html_url":"https://github.com/kain/tides-2","default_branch":"main"}"#)
        let made = try await maker().make(name: "tides", isPrivate: true, description: "")
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
        GitHubStub.on("POST /user/repos", 500, #"{"message":"Server Error"}"#)
        do {
            _ = try await maker().make(name: "tides", isPrivate: true, description: "")
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
        runs.gitStatusSource = { _ in Self.status(origin: "github.com/kain/tides", ahead: 1) }
        return (store, bot, runs)
    }

    nonisolated static func status(origin: String?, ahead: Int?, pending: Int = 1) -> DarkmuxClient.GitStatus {
        .init(branch: "mux/tides-1", head: "h1", origin: origin, defaultBranch: "main", base: "b0", pending: pending,
              upstream: nil, ahead: ahead, behind: nil, behindMain: 0, dirty: false, busy: nil)
    }

    private static let pushed = DarkmuxClient.GitPushed(branch: "mux/tides-1", head: "h1", remote: "github.com/kain/tides", addedOrigin: false)

    // 7: one push at a time per bot, through darkmux.

    @Test func pushesForABotNeverOverlap() async {
        let (store, bot, runs) = setUp()
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        let pushes = Overlap()
        runs.gitPusher = { _, _, _ in
            pushes.begin()
            try await Task.sleep(for: .milliseconds(80))
            pushes.end()
            return Self.pushed
        }
        let a = Task { await runs.backUp(bot, store: store) }
        let b = Task { await runs.backUp(bot, store: store) }
        await a.value
        await b.value
        #expect(pushes.count == 2)
        #expect(pushes.most == 1, "the second push waits for the first")
    }

    /// GitHub has commits the work copy lacks: never pushed over, and never
    /// moved to another branch name; the thread says to bring them in.
    @Test func aBranchThatMovedOnGitHubIsNeverPushedOver() async {
        let (store, bot, runs) = setUp()
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        let tries = Counter()
        runs.gitPusher = { _, _, _ in
            tries.add()
            throw DarkmuxClient.ClientError(message: "not pushed", status: 409, code: "remote_moved")
        }
        await runs.backUp(bot, store: store)
        #expect(tries.count == 1, "one try, no other branch")
        let said = (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
        #expect(said.contains { $0.contains("nothing was sent over them") }, "\(said)")
    }

    /// GitHub has everything: nothing is sent.
    @Test func nothingNewIsNotSent() async {
        let (store, bot, runs) = setUp()
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        runs.gitStatusSource = { _ in Self.status(origin: "github.com/kain/tides", ahead: 0) }
        let tries = Counter()
        runs.gitPusher = { _, _, _ in tries.add(); return Self.pushed }
        await runs.backUp(bot, store: store)
        #expect(tries.count == 0)
    }

    @Test func noBackupWhileAPutIsUnfinished() async {
        let (store, bot, runs) = setUp()
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        ModelSettingsStore.shared.setPendingRepo("kain/tides", bot: bot.id)
        defer { ModelSettingsStore.shared.setPendingRepo(nil, bot: bot.id) }
        let pushes = Overlap()
        runs.gitPusher = { _, _, _ in pushes.begin(); pushes.end(); return Self.pushed }
        await runs.backUp(bot, store: store)
        #expect(pushes.count == 0, "Put sends the project first")
    }

    /// A project an earlier Mux Bot put on GitHub (no remote in its work
    /// copy, a repo recorded): never pushed, and Start again from GitHub
    /// is offered once.
    @Test func aProjectFromAnEarlierMuxBotOffersAFreshStartFromGitHub() async {
        let (store, bot, runs) = setUp()
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        runs.gitStatusSource = { _ in Self.status(origin: nil, ahead: nil) }
        let tries = Counter()
        runs.gitPusher = { _, _, _ in tries.add(); return Self.pushed }
        await runs.backUp(bot, store: store)
        await runs.backUp(bot, store: store)
        #expect(tries.count == 0)
        let cards = (store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.kind == .actionCard }
        #expect(cards.count == 1, "offered once")
        let lines = (store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.content.contains("earlier Mux Bot") }
        #expect(lines.count == 1, "said once, with the card: \(lines.map(\.content))")
        #expect(cards.first?.action == .startFromGitHub(repo: "kain/tides"))
    }

    // 6 + 9: Put it on GitHub resumes into the repo it made.

    @Test func putOnGitHubResumesIntoTheRepoItMade() async throws {
        let (store, bot, runs) = setUp()
        let old = store.proposeRun(task: "old work", crew: .coder, on: bot)
        store.apply(.approve, to: old)
        old.keptCommit = "k1"
        store.apply(.finish(summary: "done"), to: old)
        let made = GitHubRepoMaker.Made(repo: "kain/tides", url: URL(string: "https://github.com/kain/tides")!)
        let pushes = Recorder()
        let push: PutOnGitHub.Push = { _, repo in
            pushes.add(repo)
            if pushes.values.count == 1 { throw DarkmuxClient.ClientError(message: "not pushed", status: 502, code: "push_failed") }
            return .init(branch: "main", head: "h1", remote: "github.com/\(repo)", addedOrigin: true)
        }
        do {
            _ = try await PutOnGitHub.run(bot, isPublic: false, make: { made }, push: push, store: store, runs: runs)
            Issue.record("the first push fails")
        } catch {
            #expect(error.localizedDescription.contains("kain/tides"))
        }
        #expect(bot.repoSlugs.isEmpty, "not the bot's repo until the push lands: no device clones it empty")
        #expect(PutOnGitHub.pendingRepo(bot) == "kain/tides", "kept for any device to finish into")
        #expect(PutOnGitHub.canResume(bot), "Put resumes the push into it")
        let makes = Overlap()
        _ = try await PutOnGitHub.run(bot, isPublic: false, make: { makes.begin(); makes.end(); return made }, push: push, store: store, runs: runs)
        #expect(makes.count == 0, "no second repo")
        #expect(pushes.values == ["kain/tides", "kain/tides"], "both into the same repo")
        #expect(!PutOnGitHub.canResume(bot))
        #expect(bot.repoSlugs == ["kain/tides"], "recorded once the push landed")
        #expect(PutOnGitHub.pendingRepo(bot) == nil)
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
