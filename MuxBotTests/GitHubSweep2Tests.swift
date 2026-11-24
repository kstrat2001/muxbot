import Foundation
import Testing
@testable import MuxBot

/// A GitHub whose file read fails (not "there's no file").
struct FailingFileGitHub: GitHubClient {
    func openIssues(repo: String) async throws -> [GitHubIssue] { [] }
    func issue(repo: String, number: Int) async throws -> GitHubIssue? { nil }
    func file(repo: String, path: String) async throws -> Data? { throw GitHubError(status: 502, signedIn: true) }
    func pullRequest(repo: String, number: Int) async throws -> PullRequestInfo? { nil }
}

/// Sweep 2, GitHub: sign-in renews everywhere, template backups stay right.
@Suite(.serialized) @MainActor
struct GitHubSweep2Tests {
    static let template = OwnRepoTests.template

    // 1: reads renew an expired sign-in too.

    @Test func anIssuesReadRenewsAndRetries() async throws {
        GitHubStub.reset()
        GitHubSession.refresh = { .token("fresh") }
        defer { GitHubSession.refresh = nil }
        GitHubStub.on("GET /repos/kain/site/issues", 401, #"{"message":"Bad credentials"}"#)
        GitHubStub.on("GET /repos/kain/site/issues", 200, "[]")
        let client = RESTGitHubClient(session: GitHubStub.session, token: { "old" })
        #expect(try await client.openIssues(repo: "kain/site").isEmpty)
        #expect(GitHubStub.seen.last?.auth == "Bearer fresh")
    }

    @Test func aFileReadRenewsAndRetries() async throws {
        GitHubStub.reset()
        GitHubSession.refresh = { .token("fresh") }
        defer { GitHubSession.refresh = nil }
        GitHubStub.on("GET /repos/kain/site/contents/PLAYBOOK.md", 401, #"{"message":"Bad credentials"}"#)
        GitHubStub.on("GET /repos/kain/site/contents/PLAYBOOK.md", 200, "schema: 2")
        let client = RESTGitHubClient(session: GitHubStub.session, token: { "old" })
        #expect(try await client.file(repo: "kain/site", path: "PLAYBOOK.md") == Data("schema: 2".utf8))
    }

    @Test func yourRepoListRenewsAndRetries() async throws {
        GitHubStub.reset()
        let keychain = MemoryKeychain()
        keychain.items[GitHubAuth.tokenKey] = "old"
        keychain.items[GitHubAuth.refreshKey] = "r1"
        let auth = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain,
                              defaults: UserDefaults(suiteName: "muxbot-tests-gh2-\(UUID().uuidString)")!, sleep: { _ in })
        GitHubStub.on("GET /user/repos", 401, #"{"message":"Bad credentials"}"#)
        GitHubStub.on("POST /login/oauth/access_token", 200, #"{"access_token":"new","refresh_token":"r2"}"#)
        GitHubStub.on("GET /user/repos", 200, "[]")
        let (repos, _) = try await auth.myRepos()
        #expect(repos.isEmpty)
        #expect(GitHubStub.seen.last?.auth == "Bearer new")
    }

    @Test func aPlaybookThatCantBeReadIsntNoPlaybook() async {
        #expect(await ExistingProject.fetchPlaybook(repo: "kain/site", github: FailingFileGitHub()).isFailure)
        #expect(await ExistingProject.fetchPlaybook(repo: "kain/site", github: MockGitHub()) == .none)
        let hello = ExistingProject.greeting(name: "Site", source: .github(repo: "kain/site", checkout: nil),
                                             skills: ExistingProject.skills(playbook: nil, error: "Couldn't read it."), madeHere: true)
        #expect(!hello.contains("has no PLAYBOOK.md"), "\(hello)")
        #expect(hello.contains("Couldn't read it."))
    }

    // 5: a hiccup isn't an expired sign-in.

    @Test func aGitHubHiccupDuringRenewalKeepsYouSignedIn() async {
        GitHubStub.reset()
        let keychain = MemoryKeychain()
        keychain.items[GitHubAuth.tokenKey] = "old"
        keychain.items[GitHubAuth.refreshKey] = "r1"
        let auth = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain,
                              defaults: UserDefaults(suiteName: "muxbot-tests-gh2-\(UUID().uuidString)")!, sleep: { _ in })
        GitHubStub.on("POST /login/oauth/access_token", 502, "")
        #expect(await auth.renewal() == .unreachable)
        #expect(auth.token == "old", "still signed in")
        GitHubStub.on("POST /login/oauth/access_token", 400, #"{"error":"bad_refresh_token"}"#)
        #expect(await auth.renewal() == .expired)
        #expect(auth.token == nil)
    }

    @Test func aWriterThatCantReachGitHubSaysSo() async {
        GitHubStub.reset()
        GitHubSession.refresh = { .unreachable }
        defer { GitHubSession.refresh = nil }
        GitHubStub.on("GET /user", 401, #"{"message":"Bad credentials"}"#)
        do {
            _ = try await GitHubRepoMaker(session: GitHubStub.session, token: "t").login()
            Issue.record("expected a refusal")
        } catch {
            #expect(error.localizedDescription == "Mux Bot can't reach GitHub right now.", "\(error.localizedDescription)")
        }
    }

    // 2: a template project that is on GitHub is the copy there.

    private func templateBot(_ store: BotStore) -> Bot {
        let bot = store.add(name: "Tides", instructions: "")
        bot.useCaseId = "book"
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        return bot
    }

    /// Made on iPhone and backed up: on this Mac its work copy is a clone of
    /// its repo, whose history is the project's own (darkmux #3681).
    @Test func aBackedUpTemplateProjectIsClonedFromGitHub() async {
        let store = TestStore.fresh()
        let bot = templateBot(store)
        let runs = RunCoordinator()
        runs.templateSource = { _ in Self.template }
        var asked: DarkmuxClient.WorkspaceBody?
        runs.workspaceMaker = { body in asked = body; return DarkmuxClient.Workspace(workspace: "tides-1", branch: "mux/tides-1", head: "h", repo: "github.com/kain/tides", created: true, fetchError: nil) }
        await runs.setUpWorkCopy(for: bot, store: store)
        #expect(asked?.repoURL == "https://github.com/kain/tides")
        #expect(asked?.template != true, "never a second, unrelated history")
        #expect(bot.workspaceName == "tides-1")
    }

    @Test func aLocalTemplateProjectIsStillMadeFromItsTemplate() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "Tides", instructions: "")
        bot.useCaseId = "book"
        let runs = RunCoordinator()
        runs.templateSource = { _ in Self.template }
        var asked: DarkmuxClient.WorkspaceBody?
        runs.workspaceMaker = { body in asked = body; return DarkmuxClient.Workspace(workspace: "tides-1", branch: "main", head: "h", repo: nil, created: true, fetchError: nil) }
        await runs.setUpWorkCopy(for: bot, store: store)
        #expect(asked?.template == true)
        #expect(asked?.ref == Self.template.ref)
    }

    @Test func aRunThatFinishesDuringPutIsBackedUpAfter() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "Tides", instructions: "")
        bot.useCaseId = "book"
        bot.workspaceName = "tides-1"
        let runs = RunCoordinator()
        runs.githubToken = { "ghu" }
        // No remote until Put's push lands, then darkmux's status has it.
        let landed = Counter()
        runs.gitStatusSource = { _ in OwnRepoTests.status(origin: landed.count > 0 ? "github.com/kain/tides" : nil) }
        let made = GitHubRepoMaker.Made(repo: "kain/tides", url: URL(string: "https://github.com/kain/tides")!)
        var late: BotRun?
        let push: PutOnGitHub.Push = { _, repo in
            // A run finishes while Put pushes the work it read before.
            let run = store.proposeRun(task: "late", crew: .coder, on: bot)
            store.apply(.approve, to: run)
            run.changedFiles = ["b.md +1 −0"]
            run.keptCommit = "k2"
            try? await Task.sleep(for: .milliseconds(5))
            store.apply(.finish(summary: "done"), to: run)
            late = run
            landed.add()
            return .init(branch: "main", head: "h1", remote: "github.com/\(repo)", addedOrigin: true)
        }
        let backups = Recorder()
        runs.gitPusher = { _, _, _ in backups.add("x"); return .init(branch: "mux/tides-1", head: "h2", remote: "github.com/kain/tides", addedOrigin: false) }
        _ = try await PutOnGitHub.run(bot, isPublic: false, make: { made }, push: push, store: store, runs: runs)
        #expect(backups.values.count == 1, "backed up once after Put")
        #expect(runs.unshippedRuns(bot, store: store).contains { $0.id == late?.id }, "and it's still offered for a review")
    }

    @Test func aBackupFailureIsPlainWithDarkmuxsWordsBehindDetails() async {
        let store = TestStore.fresh()
        let bot = templateBot(store)
        bot.workspaceName = "tides-1"
        let runs = RunCoordinator()
        runs.githubToken = { "ghu" }
        runs.gitStatusSource = { _ in OwnRepoTests.status() }
        runs.gitPusher = { _, _, _ in throw DarkmuxClient.ClientError(message: "fatal: bad object HEAD", status: 502, code: "push_failed") }
        await runs.backUp(bot, store: store)
        let line = (store.conversation(for: .bot(bot.id)).messages ?? []).last
        #expect(line?.content.contains("fatal") == false, "\(line?.content ?? "")")
        #expect(line.flatMap { runs.messageDetails[$0.id] }?.contains("fatal") == true)
    }
}
