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
    private let treeKey = "GET /repos/kstrat2001/muxbot-template-book/git/trees/e044900cd94d086c841616b05ed63638aa402be4"

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

    // 6: the new repo's first commit may not be there yet.

    @Test func fillingWaitsForGitHubsFirstCommit() async throws {
        GitHubStub.reset()
        GitHubStub.on(treeKey, 200, #"{"tree":[{"path":"book.json","mode":"100644","type":"blob","sha":"aaa"}],"truncated":false}"#)
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides","html_url":"https://github.com/kain/tides","default_branch":"main"}"#)
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book/git/blobs/aaa", 200, #"{"content":"e30K","encoding":"base64"}"#)
        GitHubStub.on("POST /repos/kain/tides/git/blobs", 409, #"{"message":"Git Repository is empty."}"#)
        GitHubStub.on("POST /repos/kain/tides/git/blobs", 201, #"{"sha":"n1"}"#)
        GitHubStub.on("POST /repos/kain/tides/git/trees", 201, #"{"sha":"t1"}"#)
        GitHubStub.on("GET /repos/kain/tides/git/ref/heads/main", 404, #"{"message":"Not Found"}"#)
        GitHubStub.on("GET /repos/kain/tides/git/ref/heads/main", 200, #"{"object":{"sha":"init0"}}"#)
        GitHubStub.on("POST /repos/kain/tides/git/commits", 201, #"{"sha":"start1"}"#)
        GitHubStub.on("PATCH /repos/kain/tides/git/refs/heads/main", 200, #"{"ref":"refs/heads/main"}"#)
        var maker = GitHubRepoMaker(session: GitHubStub.session, token: "t")
        maker.pause = { _ in }
        let made = try await maker.make(name: "tides", isPrivate: true, description: "", from: Self.template)
        #expect(made.startCommit == "start1")
    }

    // 2: a backed-up template project needs its GitHub start.

    private func templateBot(_ store: BotStore) -> Bot {
        let bot = store.add(name: "Tides", instructions: "")
        bot.useCaseId = "book"
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        return bot
    }

    @Test func itsProjectWaitsForItsGitHubStart() async {
        let store = TestStore.fresh()
        let bot = templateBot(store)
        let runs = RunCoordinator()
        runs.templateSource = { _ in Self.template }
        let made = Recorder()
        runs.workspaceMaker = { _ in made.add("x"); return DarkmuxClient.Workspace(workspace: "tides-1", branch: "main", head: "h", repo: nil, created: true, fetchError: nil) }
        runs.startFinder = { _, _ in nil }
        await runs.setUpWorkCopy(for: bot, store: store)
        #expect(made.values.isEmpty, "no project that could never be backed up")
        guard case let .failed(why)? = runs.workCopySetup[bot.id] else { Issue.record("not failed"); return }
        #expect(why.contains("GitHub"), "\(why)")
    }

    @Test func aBackupFindsTheStartItWasMissing() async {
        let store = TestStore.fresh()
        let bot = templateBot(store)
        bot.workspaceName = "tides-1"
        let runs = RunCoordinator()
        runs.templateSource = { _ in Self.template }
        runs.githubToken = { "ghu" }
        runs.startFinder = { _, entry in (GitHubPR.Start(commit: "s1", branch: "main", head: "mux/tides"), entry.ref) }
        runs.changesFetcher = { _ in DarkmuxClient.Changes(base: "b", baseBranch: "main", head: "h", branch: "main",
                                                           files: [.init(path: "a.md", mode: nil, content: "eA==", deleted: nil)]) }
        let heads = Recorder()
        runs.prPusher = { _, _, _, _, start in heads.add(start?.head ?? "none"); return GitHubPR.Pushed(commit: "c") }
        await runs.backUp(bot, store: store)
        #expect(heads.values == ["mux/tides"], "never darkmux's local main")
        #expect(bot.githubStart?.commit == "s1")
    }

    @Test func aTemplateProjectIsNeverPushedToItsLocalBranch() {
        let store = TestStore.fresh()
        let bot = templateBot(store)
        let runs = RunCoordinator()
        let changes = DarkmuxClient.Changes(base: "b", baseBranch: "main", head: "h", branch: "main", files: [])
        #expect(runs.pushStart(bot, changes: changes) == nil)
        #expect(!runs.canPush(bot), "no start on GitHub: Open PR refuses plainly")
    }

    // 3 + 4: Put keeps the template's tree as the base.

    @Test func afterPutTheBaseIsTheTemplateAndThePutIsTheParent() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "Tides", instructions: "")
        bot.useCaseId = "book"
        bot.workspaceName = "tides-1"
        let runs = RunCoordinator()
        runs.changesFetcher = { _ in DarkmuxClient.Changes(base: "local0", baseBranch: "main", head: "h", branch: "main",
                                                           files: [.init(path: "notes.md", mode: nil, content: "eA==", deleted: nil)]) }
        let made = GitHubRepoMaker.Made(repo: "kain/tides", url: URL(string: "https://github.com/kain/tides")!, defaultBranch: "main", startCommit: "s1")
        _ = try await PutOnGitHub.run(bot, isPublic: false, make: { made }, push: { _, _, _, _, _ in GitHubPR.Pushed(commit: "work1") },
                                      local: LocalBotState(fileURL: nil), store: store, runs: runs)
        #expect(bot.githubStart == GitHubPR.Start(commit: "s1", branch: "main", head: "mux/tides", parent: "work1"))
        // notes.md was deleted after Put: the push's tree is built on the
        // template, so the deletion shows; its parent is Put's commit.
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kain/tides/git/commits/s1", 200, #"{"sha":"s1","tree":{"sha":"tree-s1"}}"#)
        GitHubStub.on("POST /repos/kain/tides/git/trees", 201, #"{"sha":"t2"}"#)
        GitHubStub.on("POST /repos/kain/tides/git/commits", 201, #"{"sha":"c2"}"#)
        GitHubStub.on("POST /repos/kain/tides/git/refs", 201, #"{"ref":"refs/heads/mux/tides"}"#)
        let gh = GitHubPR(session: GitHubStub.session, token: "t", local: LocalBotState(fileURL: nil))
        let deleted = DarkmuxClient.Changes(base: "local0", baseBranch: "main", head: "h", branch: "main",
                                            files: [.init(path: "notes.md", mode: nil, content: nil, deleted: true)])
        _ = try await gh.push(deleted, repo: "kain/tides", message: "m", bot: bot.id, start: bot.githubStart)
        let tree = GitHubStub.seen.first { $0.method == "POST" && $0.path.hasSuffix("/git/trees") }?.body
        #expect(tree?["base_tree"] as? String == "tree-s1")
        let parents = GitHubStub.seen.first { $0.method == "POST" && $0.path.hasSuffix("/git/commits") }?.body?["parents"] as? [String]
        #expect(parents == ["work1"])
    }

    @Test func aRunThatFinishesDuringPutIsBackedUpAfter() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "Tides", instructions: "")
        bot.useCaseId = "book"
        bot.workspaceName = "tides-1"
        let runs = RunCoordinator()
        runs.githubToken = { "ghu" }
        runs.changesFetcher = { _ in DarkmuxClient.Changes(base: "local0", baseBranch: "main", head: "h", branch: "main",
                                                           files: [.init(path: "a.md", mode: nil, content: "eA==", deleted: nil)]) }
        let made = GitHubRepoMaker.Made(repo: "kain/tides", url: URL(string: "https://github.com/kain/tides")!, defaultBranch: "main", startCommit: "s1")
        var late: BotRun?
        let push: PutOnGitHub.Push = { _, _, _, _, _ in
            // A run finishes while Put pushes the work it read before.
            let run = store.proposeRun(task: "late", crew: .coder, on: bot)
            store.apply(.approve, to: run)
            run.changedFiles = ["b.md +1 −0"]
            run.keptCommit = "k2"
            try? await Task.sleep(for: .milliseconds(5))
            store.apply(.finish(summary: "done"), to: run)
            late = run
            return GitHubPR.Pushed(commit: "work1")
        }
        let backups = Recorder()
        runs.prPusher = { _, _, _, _, _ in backups.add("x"); return GitHubPR.Pushed(commit: "c") }
        _ = try await PutOnGitHub.run(bot, isPublic: false, make: { made }, push: push, local: LocalBotState(fileURL: nil), store: store, runs: runs)
        #expect(backups.values.count == 1, "backed up once after Put")
        #expect(runs.unshippedRuns(bot, store: store).contains { $0.id == late?.id }, "and it's still offered for a PR")
    }

    // 7: leftovers.

    @Test func aRepoMadeButNotFilledDuringPutResumesIntoIt() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "Tides", instructions: "")
        bot.useCaseId = "book"
        bot.workspaceName = "tides-1"
        let runs = RunCoordinator()
        runs.changesFetcher = { _ in DarkmuxClient.Changes(base: "local0", baseBranch: "main", head: "h", branch: "main", files: []) }
        do {
            _ = try await PutOnGitHub.run(bot, isPublic: false, make: { throw GitHubRepoMaker.Failure.madeButNotFilled(repo: "kain/tides", why: "busy") },
                                          push: { _, _, _, _, _ in GitHubPR.Pushed(commit: "w") }, local: LocalBotState(fileURL: nil), store: store, runs: runs)
            Issue.record("expected a failure")
        } catch {
            #expect(!error.localizedDescription.contains("another name"), "\(error.localizedDescription)")
            #expect(error.localizedDescription.contains("kain/tides"))
        }
        #expect(PutOnGitHub.canResume(bot))
        let refilled = Recorder()
        let made = GitHubRepoMaker.Made(repo: "kain/tides", url: URL(string: "https://github.com/kain/tides")!, defaultBranch: "main", startCommit: "s1")
        _ = try await PutOnGitHub.run(bot, isPublic: false, make: { Issue.record("no second repo"); return made },
                                      push: { _, _, _, _, _ in GitHubPR.Pushed(commit: "w") },
                                      refill: { repo in refilled.add(repo); return made }, local: LocalBotState(fileURL: nil), store: store, runs: runs)
        #expect(refilled.values == ["kain/tides"])
        #expect(bot.repoSlugs == ["kain/tides"])
    }

    @Test func aBackupFailureIsPlainWithDarkmuxsWordsBehindDetails() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "Tides", instructions: "")
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        bot.workspaceName = "tides-1"
        bot.githubStart = GitHubPR.Start(commit: "s1", branch: "main", head: "mux/tides")
        let runs = RunCoordinator()
        runs.githubToken = { "ghu" }
        runs.changesFetcher = { _ in throw DarkmuxClient.ClientError(message: "fatal: bad object HEAD", status: 500) }
        await runs.backUp(bot, store: store)
        let line = (store.conversation(for: .bot(bot.id)).messages ?? []).last
        #expect(line?.content.contains("fatal") == false, "\(line?.content ?? "")")
        #expect(line.flatMap { runs.messageDetails[$0.id] }?.contains("fatal") == true)
    }
}
