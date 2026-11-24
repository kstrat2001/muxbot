import Foundation
import Testing
@testable import MuxBot

/// A new project gets its own GitHub repo: private unless you choose public,
/// made empty, before anything is made on this Mac; then darkmux pushes the
/// project's own history into it (darkmux #3681), so GitHub and this Mac
/// share one history. Saved work is backed up there through darkmux.
@Suite(.serialized) @MainActor
struct OwnRepoTests {
    static let template = TemplateEntry(id: "book", repo: "kstrat2001/muxbot-template-book",
                                        ref: "e044900cd94d086c841616b05ed63638aa402be4", title: "Write a book", icon: "book.closed")
    private func maker() -> GitHubRepoMaker { GitHubRepoMaker(session: GitHubStub.session, token: "ghu_abc") }

    private func body(_ method: String, _ suffix: String) -> [String: Any] {
        GitHubStub.seen.first { $0.method == method && $0.path.hasSuffix(suffix) }?.body ?? [:]
    }

    nonisolated static func status(origin: String? = "github.com/kain/tides", ahead: Int? = 1, pending: Int = 1) -> DarkmuxClient.GitStatus {
        .init(branch: "mux/tides-1", head: "h1", origin: origin, defaultBranch: "main", base: "b0", pending: pending,
              upstream: nil, ahead: ahead, behind: nil, behindMain: 0, dirty: false, busy: nil)
    }

    /// GitHub is optional: off for someone not signed in, on once signed in
    /// unless you last switched it off.
    @Test func backUpStartsOffUntilYouSignIn() {
        let defaults = UserDefaults(suiteName: "muxbot-tests-backup-\(UUID().uuidString)")!
        #expect(!StartProject.Answers(name: "Tides").backUpToGitHub)
        #expect(!StartProject.backUpDefault(signedIn: false, defaults: defaults), "a new user never meets a sign-in")
        #expect(StartProject.backUpDefault(signedIn: true, defaults: defaults))
        StartProject.rememberBackUp(false, defaults: defaults)
        #expect(!StartProject.backUpDefault(signedIn: true, defaults: defaults), "your last choice is kept")
        StartProject.rememberBackUp(true, defaults: defaults)
        #expect(!StartProject.backUpDefault(signedIn: false, defaults: defaults), "never on while signed out")
        #expect(StartProject.backUpDefault(signedIn: true, defaults: defaults))
    }

    @Test func theRepoIsPrivateByDefaultAndMadeEmpty() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides","html_url":"https://github.com/kain/tides"}"#)
        let made = try await maker().make(name: "tides", isPrivate: true, description: "a book")
        #expect(made == .init(repo: "kain/tides", url: URL(string: "https://github.com/kain/tides")!))
        let create = body("POST", "/user/repos")
        #expect(create["private"] as? Bool == true)
        #expect(create["auto_init"] as? Bool == false, "darkmux pushes the project's own first commit")
        #expect(create["name"] as? String == "tides")
        #expect(!GitHubStub.seen.contains { $0.path.contains("/forks") || $0.path.contains("/generate") || $0.path.contains("/git/") },
                "no fork, no link, nothing copied through GitHub")
    }

    @Test func publicOnlyWhenYouSaySo() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides","html_url":"https://github.com/kain/tides"}"#)
        _ = try await maker().make(name: "tides", isPrivate: false, description: "")
        #expect(body("POST", "/user/repos")["private"] as? Bool == false)
    }

    @Test func aTakenNameGetsTheNextFreeOne() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kain/tides", 200, #"{"name":"tides"}"#)
        GitHubStub.on("GET /repos/kain/tides-2", 200, #"{"name":"tides-2"}"#)
        #expect(try await maker().freeName("tides", owner: "kain") == "tides-3")
        #expect(GitHubRepoMaker.slug("How I  Made darkmux!") == "how-i-made-darkmux")
        #expect(GitHubRepoMaker.slug("  ") == "project")
    }

    @Test func withoutTheRepositoryCreationPermissionItSaysSo() async {
        GitHubStub.reset()
        GitHubStub.on("POST /user/repos", 403, #"{"message":"Resource not accessible by integration"}"#)
        await #expect(throws: GitHubRepoMaker.Failure.cantCreate) {
            _ = try await maker().make(name: "tides", isPrivate: true, description: "")
        }
        let said = GitHubRepoMaker.Failure.cantCreate.localizedDescription
        #expect(said.contains("can't create repositories"), "\(said)")
        #expect(!said.contains("settings"), "never a step only the App's owner can take: \(said)")
    }

    @Test func whenGitHubFailsNothingIsMadeHere() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /user", 200, #"{"login":"kain"}"#)
        GitHubStub.on("POST /user/repos", 403, #"{"message":"Resource not accessible by integration"}"#)
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.runs.workspaceMaker = { _ in Issue.record("nothing local"); throw CancellationError() }
        let playbook = try #require(TemplateRegistry.bundledPlaybook(for: "book"))
        await #expect(throws: GitHubRepoMaker.Failure.cantCreate) {
            _ = try await StartProject.start(Self.template, playbook: playbook, answers: .init(name: "Tides", purpose: "a winter", backUpToGitHub: true),
                                             github: maker(), store: store, runs: brain.runs)
        }
        #expect(store.allBots().isEmpty)
    }

    /// The empty repo first, then the local project from the template, then
    /// darkmux pushes it into that repo.
    @Test func theBotRecordsItsNewRepoAndDarkmuxPushesTheProjectIntoIt() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /user", 200, #"{"login":"kain"}"#)
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides","html_url":"https://github.com/kain/tides"}"#)
        let store = TestStore.fresh()
        let brain = BotBrain()
        var asked: DarkmuxClient.WorkspaceBody?
        brain.runs.workspaceMaker = { body in asked = body; return DarkmuxClient.Workspace(workspace: "tides-1", branch: "main", created: true) }
        brain.runs.gitStatusSource = { _ in Self.status(origin: nil, ahead: nil) }
        let pushedTo = Recorder()
        brain.runs.gitPusher = { workspace, github, repo in
            pushedTo.add("\(workspace) \(github ?? "-") \(repo ?? "-")")
            return .init(branch: "main", head: "h1", remote: "github.com/kain/tides", addedOrigin: true)
        }
        let playbook = try #require(TemplateRegistry.bundledPlaybook(for: "book"))
        let bot = try await StartProject.start(Self.template, playbook: playbook, answers: .init(name: "Tides", purpose: "a winter", backUpToGitHub: true),
                                               github: maker(), store: store, runs: brain.runs)
        #expect(bot.repoSlugs == ["kain/tides"])
        #expect(asked?.template == true)
        #expect(asked?.ref == Self.template.ref)
        #expect(pushedTo.values == ["tides-1 ghu_abc kain/tides"], "the project's history into the new repo, with your sign-in")
        #expect(!PutOnGitHub.canResume(bot), "finished")
        #expect(GitHubStub.seen.first?.path == "/user", "GitHub first, then this Mac")
        #expect(body("POST", "/user/repos")["private"] as? Bool == true, "private unless you switch Public on")
    }

    @Test func switchedOffNothingGoesToGitHub() async throws {
        GitHubStub.reset()
        let store = TestStore.fresh()
        let brain = BotBrain()
        var asked: DarkmuxClient.WorkspaceBody?
        brain.runs.workspaceMaker = { body in asked = body; return DarkmuxClient.Workspace(workspace: "tides-1", branch: "main", created: true) }
        brain.runs.gitPusher = { _, _, _ in Issue.record("nothing pushed"); throw CancellationError() }
        let playbook = try #require(TemplateRegistry.bundledPlaybook(for: "book"))
        let bot = try await StartProject.start(Self.template, playbook: playbook, answers: .init(name: "Tides", purpose: "a winter", backUpToGitHub: false),
                                               github: maker(), store: store, runs: brain.runs)
        #expect(GitHubStub.seen.isEmpty, "no sign-in needed, nothing sent")
        #expect(bot.repoSlugs.isEmpty)
        #expect(asked?.template == true, "the local project is still made")
    }

    @Test func keepingItOnGitHubNeedsASignIn() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.runs.workspaceMaker = { _ in Issue.record("nothing local"); throw CancellationError() }
        let playbook = try #require(TemplateRegistry.bundledPlaybook(for: "book"))
        await #expect(throws: GitHubRepoMaker.Failure.self) {
            _ = try await StartProject.start(Self.template, playbook: playbook,
                                             answers: .init(name: "Tides", purpose: "a winter", backUpToGitHub: true),
                                             github: nil, store: store, runs: brain.runs)
        }
        #expect(store.allBots().isEmpty)
    }

    private func backedUpBot(_ store: BotStore) -> Bot {
        let bot = store.add(name: "Tides", instructions: "")
        bot.useCaseId = "book"
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        bot.workspaceName = "tides-1"
        return bot
    }

    @Test func savedWorkIsBackedUpThroughDarkmux() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = backedUpBot(store)
        brain.runs.githubToken = { "ghu_abc" }
        brain.runs.gitStatusSource = { _ in Self.status() }
        let pushed = Recorder()
        brain.runs.gitPusher = { workspace, github, repo in
            pushed.add("\(workspace) \(github ?? "-") \(repo ?? "-")")
            return .init(branch: "mux/tides-1", head: "h1", remote: "github.com/kain/tides", addedOrigin: false)
        }
        await brain.runs.backUp(bot, store: store)
        #expect(pushed.values == ["tides-1 ghu_abc -"], "its own branch, to its own remote")
    }

    /// An Undo still reaches GitHub: darkmux's revert is a commit GitHub
    /// lacks (`ahead`). With nothing new, nothing is sent (#137).
    @Test func whatGitHubLacksIsSentAndNothingElse() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = backedUpBot(store)
        brain.runs.githubToken = { "ghu_abc" }
        let ahead = Counter()
        brain.runs.gitStatusSource = { _ in Self.status(ahead: ahead.count) }
        let pushed = Counter()
        brain.runs.gitPusher = { _, _, _ in pushed.add(); return .init(branch: "mux/tides-1", head: "h1", remote: "github.com/kain/tides", addedOrigin: false) }
        await brain.runs.sendToGitHub(bot, store: store)
        #expect(pushed.count == 0)
        ahead.add()
        await brain.runs.sendToGitHub(bot, store: store)
        #expect(pushed.count == 1)
    }

    @Test func aDarkmuxWithoutTheGitRouteSaysItNeedsAnUpdate() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = backedUpBot(store)
        brain.runs.githubToken = { "ghu_abc" }
        brain.runs.capabilitiesSource = { [] }
        brain.runs.gitStatusSource = { _ in Self.status() }
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-ownrepo-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        brain.runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        await brain.runs.backUp(bot, store: store)
        let said = (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
        #expect(said.contains { $0.contains(RunCoordinator.darkmuxNeedsUpdate) }, "\(said)")
        #expect(!said.contains { $0.contains("Terminal") || $0.contains("brew") }, "no commands")
    }

    @Test func theBackupNeverWaitsOnTheNotificationPrompt() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = backedUpBot(store)
        brain.runs.githubToken = { "ghu_abc" }
        brain.runs.gitStatusSource = { _ in Self.status() }
        let pushed = Counter()
        brain.runs.gitPusher = { _, _, _ in pushed.add(); return .init(branch: "mux/tides-1", head: "h1", remote: "github.com/kain/tides", addedOrigin: false) }
        // macOS's "allow notifications?" prompt that nobody answers.
        brain.runs.noticePoster = { _, _ in try? await Task.sleep(for: .seconds(3600)) }
        let run = store.proposeRun(task: "Fix it", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        let finishing = Task { await brain.runs.finishRun(run, status: try! JSONDecoder().decode(DarkmuxClient.WorkStatus.self,
            from: Data(#"{"status":"done","result":{"final_assistant":"done"},"changes":{"files":[{"path":"a.txt","added":1,"removed":0}]},"commit":"abc1234","branch":"main"}"#.utf8)),
                                                               store: store) }
        for _ in 0..<50 where pushed.count == 0 { try await Task.sleep(for: .milliseconds(100)) }
        finishing.cancel()
        #expect(pushed.count == 1, "backed up while the prompt waits")
    }
}

/// "Put it on GitHub" later, for a project that started on this Mac only.
@Suite(.serialized) @MainActor
struct PutOnGitHubTests {
    private func localBot(_ store: BotStore) -> Bot {
        let bot = store.add(name: "Tides", instructions: "")
        bot.useCaseId = "book"
        bot.workspaceName = "tides-1"
        return bot
    }

    @Test func itsOfferedOnlyForALocalTemplateProject() {
        let store = TestStore.fresh()
        let bot = localBot(store)
        #expect(PutOnGitHub.canPut(bot))
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        #expect(!PutOnGitHub.canPut(bot), "already has a repo")
        let notHere = store.add(name: "Elsewhere", instructions: "")
        notHere.useCaseId = "book"
        #expect(!PutOnGitHub.canPut(notHere), "no work copy on this Mac")
    }

    /// An empty repo, then darkmux pushes the project into it: GitHub gets
    /// the project's own history, nothing rebuilt by the app.
    @Test func theRepoIsMadeEmptyThenDarkmuxPushesTheProjectIntoIt() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /user", 200, #"{"login":"kain"}"#)
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides","html_url":"https://github.com/kain/tides"}"#)
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = localBot(store)
        brain.runs.gitStatusSource = { _ in OwnRepoTests.status(origin: nil, ahead: nil) }
        let pushed = Recorder()
        brain.runs.gitPusher = { _, github, repo in
            pushed.add("\(github ?? "-") \(repo ?? "-")")
            return .init(branch: "main", head: "h1", remote: "github.com/kain/tides", addedOrigin: true)
        }
        let made = try await PutOnGitHub.run(bot, isPublic: false, github: GitHubRepoMaker(session: GitHubStub.session, token: "t"),
                                             token: "t", store: store, runs: brain.runs)
        #expect(made.repo == "kain/tides")
        #expect(GitHubStub.seen.first { $0.path == "/user/repos" }?.body?["private"] as? Bool == true)
        #expect(!GitHubStub.seen.contains { $0.path.contains("/git/") }, "nothing copied through GitHub's API")
        #expect(pushed.values == ["t kain/tides"])
        #expect(bot.repoSlugs == ["kain/tides"])
        #expect(!PutOnGitHub.canResume(bot))
    }
}
