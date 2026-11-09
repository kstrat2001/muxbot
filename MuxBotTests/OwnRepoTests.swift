import Foundation
import Testing
@testable import MuxBot

/// A new project gets its own GitHub repo: private unless you choose public,
/// filled with the template's files at its pinned commit as one commit (no
/// fork, no link), before anything is made on this Mac. Committed work is
/// backed up to `mux/<bot>` there, and Open PR builds on the GitHub start.
@Suite(.serialized) @MainActor
struct OwnRepoTests {
    static let template = TemplateEntry(id: "book", repo: "kstrat2001/muxbot-template-book",
                                        ref: "e044900cd94d086c841616b05ed63638aa402be4", title: "Write a book", icon: "book.closed")
    private func maker() -> GitHubRepoMaker { GitHubRepoMaker(session: GitHubStub.session, token: "ghu_abc") }

    /// GitHub answers for a template of two files, one executable.
    private func stubTemplateAndFill(created: String = "kain/tides") {
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book/git/trees/e044900cd94d086c841616b05ed63638aa402be4", 200,
                      #"{"tree":[{"path":"book.json","mode":"100644","type":"blob","sha":"aaa"},{"path":"scripts/x.sh","mode":"100755","type":"blob","sha":"bbb"},{"path":"scripts","mode":"040000","type":"tree","sha":"ccc"}],"truncated":false}"#)
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book/git/blobs/aaa", 200, #"{"content":"e30K\n","encoding":"base64"}"#)
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book/git/blobs/bbb", 200, #"{"content":"ZWNobwo=","encoding":"base64"}"#)
        GitHubStub.on("POST /repos/\(created)/git/blobs", 201, #"{"sha":"n1"}"#)
        GitHubStub.on("POST /repos/\(created)/git/blobs", 201, #"{"sha":"n2"}"#)
        GitHubStub.on("POST /repos/\(created)/git/trees", 201, #"{"sha":"t1"}"#)
        GitHubStub.on("GET /repos/\(created)/git/ref/heads/main", 200, #"{"object":{"sha":"init0"}}"#)
        GitHubStub.on("POST /repos/\(created)/git/commits", 201, #"{"sha":"start1"}"#)
        GitHubStub.on("PATCH /repos/\(created)/git/refs/heads/main", 200, #"{"ref":"refs/heads/main"}"#)
    }

    private func body(_ method: String, _ suffix: String) -> [String: Any] {
        GitHubStub.seen.first { $0.method == method && $0.path.hasSuffix(suffix) }?.body ?? [:]
    }

    @Test func theRepoIsPrivateByDefaultAndHoldsExactlyTheTemplate() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides","html_url":"https://github.com/kain/tides","default_branch":"main"}"#)
        stubTemplateAndFill()
        let made = try await maker().make(name: "tides", isPrivate: true, description: "a book", from: Self.template)
        #expect(made == .init(repo: "kain/tides", url: URL(string: "https://github.com/kain/tides")!, defaultBranch: "main", startCommit: "start1"))
        let create = body("POST", "/user/repos")
        #expect(create["private"] as? Bool == true)
        #expect(create["auto_init"] as? Bool == true, "the Git Data API can't write to an empty repo")
        #expect(create["name"] as? String == "tides")
        let tree = body("POST", "/git/trees")
        #expect(tree["base_tree"] == nil, "only the template's files")
        let entries = tree["tree"] as? [[String: Any]] ?? []
        #expect(entries.compactMap { $0["path"] as? String } == ["book.json", "scripts/x.sh"])
        #expect(entries.compactMap { $0["mode"] as? String } == ["100644", "100755"])
        let blobs = GitHubStub.seen.filter { $0.method == "POST" && $0.path.hasSuffix("/git/blobs") }.compactMap { $0.body?["content"] as? String }
        #expect(blobs == ["e30K", "ZWNobwo="], "the template's bytes, exactly")
        #expect(body("POST", "/git/commits")["parents"] as? [String] == ["init0"])
        #expect((body("PATCH", "/git/refs/heads/main")["force"] as? Bool) == false, "never a force push")
        #expect(!GitHubStub.seen.contains { $0.path.contains("/forks") || $0.path.contains("/generate") }, "no fork, no link")
    }

    @Test func publicOnlyWhenYouSaySo() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides","html_url":"https://github.com/kain/tides","default_branch":"main"}"#)
        stubTemplateAndFill()
        _ = try await maker().make(name: "tides", isPrivate: false, description: "", from: Self.template)
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
            _ = try await maker().make(name: "tides", isPrivate: true, description: "", from: Self.template)
        }
        #expect(GitHubRepoMaker.Failure.cantCreate.localizedDescription.contains("Repository creation"))
    }

    @Test func aRepoMadeButNotFilledIsReportedByName() async {
        GitHubStub.reset()
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides","html_url":"https://github.com/kain/tides","default_branch":"main"}"#)
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book/git/trees/e044900cd94d086c841616b05ed63638aa402be4", 500, #"{"message":"boom"}"#)
        do {
            _ = try await maker().make(name: "tides", isPrivate: true, description: "", from: Self.template)
            Issue.record("should fail")
        } catch let failure as GitHubRepoMaker.Failure {
            guard case let .madeButNotFilled(repo, _) = failure else { Issue.record("\(failure)"); return }
            #expect(repo == "kain/tides")
            #expect(failure.localizedDescription.contains("github.com/kain/tides"))
        } catch { Issue.record("\(error)") }
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
            _ = try await StartProject.start(Self.template, playbook: playbook, answers: .init(name: "Tides", purpose: "a winter"),
                                             github: maker(), store: store, runs: brain.runs)
        }
        #expect(store.allBots().isEmpty)
    }

    @Test func theBotRecordsItsNewRepoAndDarkmuxStartsFromTheSameCommit() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /user", 200, #"{"login":"kain"}"#)
        GitHubStub.on("POST /user/repos", 201, #"{"full_name":"kain/tides","html_url":"https://github.com/kain/tides","default_branch":"main"}"#)
        stubTemplateAndFill()
        let store = TestStore.fresh()
        let brain = BotBrain()
        var asked: DarkmuxClient.WorkspaceBody?
        brain.runs.workspaceMaker = { body in asked = body; return DarkmuxClient.Workspace(workspace: "tides-1", branch: "main", created: true) }
        let playbook = try #require(TemplateRegistry.bundledPlaybook(for: "book"))
        let bot = try await StartProject.start(Self.template, playbook: playbook, answers: .init(name: "Tides", purpose: "a winter"),
                                               github: maker(), store: store, runs: brain.runs)
        #expect(bot.repoSlugs == ["kain/tides"])
        #expect(asked?.template == true)
        #expect(asked?.ref == Self.template.ref, "the same commit as the repo's first")
        #expect(bot.githubStart == GitHubPR.Start(commit: "start1", branch: "main", head: "mux/tides"))
        #expect(GitHubStub.seen.first?.path == "/user", "GitHub first, then this Mac")
        #expect(body("POST", "/user/repos")["private"] as? Bool == true, "private unless you switch Public on")
    }

    @Test func committedWorkIsBackedUpToTheBotsBranch() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = store.add(name: "Tides", instructions: "")
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        bot.workspaceName = "tides-1"
        bot.githubStart = GitHubPR.Start(commit: "start1", branch: "main", head: "mux/tides")
        brain.runs.githubToken = { "ghu_abc" }
        let changes = DarkmuxClient.Changes(base: "local0", baseBranch: "main", head: "h", branch: "main",
                                            files: [.init(path: "book.json", mode: "100644", content: "e30K", deleted: nil)])
        brain.runs.changesFetcher = { _ in changes }
        var pushed: (String, GitHubPR.Start?)?
        brain.runs.prPusher = { _, repo, _, _, start in pushed = (repo, start); return GitHubPR.Pushed(commit: "c1") }
        await brain.runs.backUp(bot, store: store)
        #expect(pushed?.0 == "kain/tides")
        #expect(pushed?.1?.head == "mux/tides")
    }

    @Test func thePushBuildsOnTheGitHubStartAndGoesToTheBotsBranch() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /repos/kain/tides/git/blobs", 201, #"{"sha":"b1"}"#)
        GitHubStub.on("GET /repos/kain/tides/git/commits/start1", 200, #"{"sha":"start1","tree":{"sha":"tree0"}}"#)
        GitHubStub.on("POST /repos/kain/tides/git/trees", 201, #"{"sha":"t1"}"#)
        GitHubStub.on("POST /repos/kain/tides/git/commits", 201, #"{"sha":"c1"}"#)
        GitHubStub.on("POST /repos/kain/tides/git/refs", 201, #"{"ref":"refs/heads/mux/tides"}"#)
        let changes = DarkmuxClient.Changes(base: "local0", baseBranch: "main", head: "h", branch: "main",
                                            files: [.init(path: "book.json", mode: "100644", content: "e30K", deleted: nil)])
        let gh = GitHubPR(session: GitHubStub.session, token: "t", local: LocalBotState(fileURL: nil))
        let pushed = try await gh.push(changes, repo: "kain/tides", message: "Back up", bot: UUID(),
                                       start: GitHubPR.Start(commit: "start1", branch: "main", head: "mux/tides"))
        #expect(pushed.commit == "c1")
        #expect(body("POST", "/git/commits")["parents"] as? [String] == ["start1"], "darkmux's local first commit isn't on GitHub")
        #expect(body("POST", "/git/refs")["ref"] as? String == "refs/heads/mux/tides", "never main")
        #expect(!GitHubStub.seen.contains { $0.path.hasSuffix("/pulls") }, "a backup opens no PR")
    }
}
