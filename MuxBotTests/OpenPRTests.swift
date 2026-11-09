import Foundation
import Testing
@testable import MuxBot

@Suite(.serialized) @MainActor
struct OpenPRTests {
    private let changes = DarkmuxClient.Changes(
        base: "b0b0", baseBranch: "main", head: "h1h1", branch: "mux/hcr-3cfe8f",
        files: [
            .init(path: "inertia/pages/pricing.tsx", mode: "100644", content: "Y2hhbmdlZAo=", deleted: nil),
            .init(path: "gone.txt", mode: nil, content: nil, deleted: true),
        ])
    private let bot = UUID()

    /// A PR client with this Mac's record of the commit it last wrote to the
    /// bot's branch, if any.
    private func client(token: String = "t", pushed: String? = nil) -> (GitHubPR, LocalBotState) {
        let local = LocalBotState(fileURL: nil)
        if let pushed { local.update(bot) { $0.pushedHeads = [changes.branch: pushed] } }
        return (GitHubPR(session: GitHubStub.session, token: token, local: local), local)
    }

    private func pushed(_ local: LocalBotState) -> String? { local[bot]?.pushedHeads?[changes.branch] }

    @Test func changesFromDarkmuxDecode() throws {
        let json = #"{"base":"b0b0","base_branch":"main","head":"h1h1","branch":"mux/hcr-3cfe8f","files":[{"path":"a.txt","mode":"100644","content":"YQ=="},{"path":"gone.txt","deleted":true}]}"#
        let c = try JSONDecoder().decode(DarkmuxClient.Changes.self, from: Data(json.utf8))
        #expect(c.baseBranch == "main")
        #expect(c.files[1].deleted == true)
    }

    @Test func theAppOpensThePRThroughTheGitDataAPI() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/blobs", 201, #"{"sha":"blob1"}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/git/commits/b0b0", 200, #"{"sha":"b0b0","tree":{"sha":"tree0"}}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/trees", 201, #"{"sha":"tree1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/commits", 201, #"{"sha":"commit1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/refs", 201, #"{"ref":"refs/heads/mux/hcr-3cfe8f"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/pulls", 201, #"{"number":12,"html_url":"https://github.com/kstrat2001/hcr/pull/12"}"#)
        let (gh, local) = client(token: "ghu_abc")
        let pr = try await gh.open(changes, repo: "kstrat2001/hcr", title: "Fix #10: tablet nav", body: "Body", bot: bot)
        #expect(pr.number == 12)
        #expect(pr.url.absoluteString == "https://github.com/kstrat2001/hcr/pull/12")
        let body = { (path: String) in GitHubStub.seen.first { $0.method == "POST" && $0.path.hasSuffix(path) }?.body ?? [:] }
        #expect(body("/git/blobs")["encoding"] as? String == "base64")
        #expect(body("/git/blobs")["content"] as? String == "Y2hhbmdlZAo=")
        let tree = body("/git/trees")
        #expect(tree["base_tree"] as? String == "tree0")
        let entries = tree["tree"] as? [[String: Any]] ?? []
        #expect(entries.first { $0["path"] as? String == "inertia/pages/pricing.tsx" }?["sha"] as? String == "blob1")
        #expect(entries.first { $0["path"] as? String == "gone.txt" }?["sha"] is NSNull, "a deletion")
        #expect(body("/git/commits")["parents"] as? [String] == ["b0b0"], "a new branch starts on the base")
        #expect(body("/git/refs")["ref"] as? String == "refs/heads/mux/hcr-3cfe8f")
        #expect(body("/git/refs")["sha"] as? String == "commit1")
        let pull = body("/pulls")
        #expect(pull["head"] as? String == "mux/hcr-3cfe8f")
        #expect(pull["base"] as? String == "main")
        #expect(pull["title"] as? String == "Fix #10: tablet nav")
        #expect(GitHubStub.seen.allSatisfy { $0.auth == "Bearer ghu_abc" })
        #expect(pushed(local) == "commit1", "this Mac remembers what it wrote to the branch")
    }

    @Test func anExistingBranchGetsANewCommitOnTopNeverAForcePush() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/blobs", 201, #"{"sha":"blob1"}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/git/commits/b0b0", 200, #"{"sha":"b0b0","tree":{"sha":"tree0"}}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/git/ref/heads/mux/hcr-3cfe8f", 200, #"{"ref":"refs/heads/mux/hcr-3cfe8f","object":{"sha":"remote1"}}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/trees", 201, #"{"sha":"tree1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/commits", 201, #"{"sha":"commit2"}"#)
        GitHubStub.on("PATCH /repos/kstrat2001/hcr/git/refs/heads/mux/hcr-3cfe8f", 200, #"{"ref":"refs/heads/mux/hcr-3cfe8f"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/pulls", 422, #"{"message":"Validation Failed","errors":[{"message":"A pull request already exists for kstrat2001:mux/hcr-3cfe8f."}]}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/pulls", 200, #"[{"number":12,"html_url":"https://github.com/kstrat2001/hcr/pull/12"}]"#)
        let (gh, local) = client(pushed: "remote1")
        let pr = try await gh.open(changes, repo: "kstrat2001/hcr", title: "x", body: "y", bot: bot)
        #expect(pr.number == 12, "the open PR is reused")
        let body = { (method: String, path: String) in GitHubStub.seen.first { $0.method == method && $0.path.hasSuffix(path) }?.body ?? [:] }
        #expect(body("POST", "/git/commits")["parents"] as? [String] == ["remote1"], "on top of the branch as it is on GitHub")
        #expect(body("POST", "/git/trees")["base_tree"] as? String == "tree0", "the full current state")
        let patch = body("PATCH", "/git/refs/heads/mux/hcr-3cfe8f")
        #expect(patch["sha"] as? String == "commit2")
        #expect((patch["force"] as? Bool ?? false) == false, "never a force push")
        #expect(!GitHubStub.seen.contains { $0.method == "POST" && $0.path.hasSuffix("/git/refs") })
        #expect(pushed(local) == "commit2")
    }

    /// The branch on GitHub is at a commit this Mac didn't write (someone
    /// pushed on top of ours, or it was never ours): a commit on top of it
    /// with our tree would drop their changes, so nothing is written.
    @Test(arguments: [Optional("ours1"), nil])
    func aBranchThatMovedStopsBeforeWritingAnything(lastPushed: String?) async {
        GitHubStub.reset()
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/blobs", 201, #"{"sha":"blob1"}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/git/commits/b0b0", 200, #"{"sha":"b0b0","tree":{"sha":"tree0"}}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/git/ref/heads/mux/hcr-3cfe8f", 200, #"{"object":{"sha":"theirs2"}}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/trees", 201, #"{"sha":"tree1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/commits", 201, #"{"sha":"commit2"}"#)
        GitHubStub.on("PATCH /repos/kstrat2001/hcr/git/refs/heads/mux/hcr-3cfe8f", 200, #"{"ref":"refs/heads/mux/hcr-3cfe8f"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/pulls", 201, #"{"number":12,"html_url":"https://github.com/kstrat2001/hcr/pull/12"}"#)
        let (gh, local) = client(pushed: lastPushed)
        do {
            _ = try await gh.open(changes, repo: "kstrat2001/hcr", title: "x", body: "y", bot: bot)
            Issue.record("expected it to stop")
        } catch let error as GitHubPR.Failure {
            #expect(error == .branchMoved("mux/hcr-3cfe8f"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        let writes = GitHubStub.seen.filter { $0.method != "GET" }.map { "\($0.method) \($0.path)" }
        #expect(writes.isEmpty, "no blob, tree, commit, ref move or PR: \(writes)")
        #expect(pushed(local) == lastPushed)
    }

    @Test func anotherRefusalOfTheMoveSaysWhatGitHubSaid() async {
        GitHubStub.reset()
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/blobs", 201, #"{"sha":"blob1"}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/git/commits/b0b0", 200, #"{"sha":"b0b0","tree":{"sha":"tree0"}}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/git/ref/heads/mux/hcr-3cfe8f", 200, #"{"object":{"sha":"remote1"}}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/trees", 201, #"{"sha":"tree1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/commits", 201, #"{"sha":"commit2"}"#)
        GitHubStub.on("PATCH /repos/kstrat2001/hcr/git/refs/heads/mux/hcr-3cfe8f", 422, #"{"message":"Reference cannot be updated"}"#)
        do {
            _ = try await client(pushed: "remote1").0.open(changes, repo: "kstrat2001/hcr", title: "x", body: "y", bot: bot)
            Issue.record("expected an error")
        } catch let error as GitHubPR.Failure {
            #expect(error == .github("Reference cannot be updated"), "not someone else's push")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func thePushIsRememberedEvenIfThePRThenFails() async {
        GitHubStub.reset()
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/blobs", 201, #"{"sha":"blob1"}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/git/commits/b0b0", 200, #"{"sha":"b0b0","tree":{"sha":"tree0"}}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/trees", 201, #"{"sha":"tree1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/commits", 201, #"{"sha":"commit1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/refs", 201, #"{"ref":"refs/heads/mux/hcr-3cfe8f"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/pulls", 500, #"{"message":"Server Error"}"#)
        let (gh, local) = client()
        _ = try? await gh.open(changes, repo: "kstrat2001/hcr", title: "x", body: "y", bot: bot)
        #expect(pushed(local) == "commit1", "the branch is ours at commit1, so the next try can move it")
    }

    @Test func ifGitHubRefusesTheMoveAsNotAFastForwardItStops() async {
        GitHubStub.reset()
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/blobs", 201, #"{"sha":"blob1"}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/git/commits/b0b0", 200, #"{"sha":"b0b0","tree":{"sha":"tree0"}}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/git/ref/heads/mux/hcr-3cfe8f", 200, #"{"object":{"sha":"remote1"}}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/trees", 201, #"{"sha":"tree1"}"#)
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/commits", 201, #"{"sha":"commit2"}"#)
        GitHubStub.on("PATCH /repos/kstrat2001/hcr/git/refs/heads/mux/hcr-3cfe8f", 422, #"{"message":"Update is not a fast forward"}"#)
        let (gh, local) = client(pushed: "remote1")
        do {
            _ = try await gh.open(changes, repo: "kstrat2001/hcr", title: "x", body: "y", bot: bot)
            Issue.record("expected it to stop")
        } catch let error as GitHubPR.Failure {
            #expect(error == .branchMoved("mux/hcr-3cfe8f"))
            #expect(error.localizedDescription.contains("mux/hcr-3cfe8f"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(!GitHubStub.seen.contains { $0.path.hasSuffix("/pulls") }, "no PR from a branch it couldn't update")
        #expect(pushed(local) == "remote1")
    }

    @Test func aRepoTheAppCantWriteToSaysSo() async {
        GitHubStub.reset()
        GitHubStub.on("POST /repos/kstrat2001/hcr/git/blobs", 404, #"{"message":"Not Found"}"#)
        do {
            _ = try await client().0.open(changes, repo: "kstrat2001/hcr", title: "x", body: "y", bot: bot)
            Issue.record("expected an error")
        } catch let error as GitHubPR.Failure {
            #expect(error == .cantWrite("kstrat2001/hcr"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func titleAndBodyComeFromTheRuns() {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        let a = store.proposeRun(task: "Fix #10: tablet nav (kstrat2001/hcr)", crew: .coder, on: bot)
        store.apply(.approve, to: a); a.changedFiles = ["x +1 −0"]; a.keptCommit = "abc1234"
        store.apply(.finish(summary: "I switched to the mobile nav below 900px."), to: a)
        let one = PRText.make(bot: bot, runs: [a], machine: "MacBook Pro")
        #expect(one.title == "Fix #10: tablet nav")
        #expect(one.body.contains("I switched to the mobile nav below 900px."))
        #expect(one.body.contains("Fixes #10"))
        let b = store.proposeRun(task: "Tighten footer spacing", crew: .coder, on: bot)
        store.apply(.approve, to: b); b.changedFiles = ["y +1 −0"]; b.keptCommit = "def5678"
        store.apply(.finish(summary: "Footer gap is 24px now."), to: b)
        let two = PRText.make(bot: bot, runs: [a, b], machine: "MacBook Pro")
        #expect(two.title == "hcr: 2 changes")
        #expect(two.body.contains("Tighten footer spacing"))
        #expect(two.body.contains("darkmux"))
    }

    @Test func prLinksAreFoundInTheThread() {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        let thread = store.conversation(for: .bot(bot.id))
        store.append(.system, "Opened PR #12: https://github.com/kstrat2001/hcr/pull/12", kind: .prCard, to: thread)
        #expect(PRLinks.latest(in: thread.messages ?? [])?.absoluteString == "https://github.com/kstrat2001/hcr/pull/12")
    }
}

@Suite(.serialized) @MainActor
struct OpenPRAvailabilityTests {
    @Test func openPRShowsForCommittedRunsNotYetInAPR() {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        bot.workspaceName = "hcr-ws"
        let keychain = MemoryKeychain(); keychain.items[GitHubAuth.tokenKey] = "ghu_abc"
        let github = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain)
        let runs = RunCoordinator()
        #expect(!runs.canOpenPR(bot, store: store, github: github), "nothing committed yet")
        let run = store.proposeRun(task: "Fix #10", crew: .coder, on: bot)
        store.apply(.approve, to: run); run.changedFiles = ["a +1 −0"]; run.keptCommit = "abc1234"
        store.apply(.finish(summary: "Done."), to: run)
        run.finishedAt = Date().addingTimeInterval(-60)
        #expect(runs.canOpenPR(bot, store: store, github: github))
        store.append(.system, "Opened PR #12: https://github.com/kstrat2001/hcr/pull/12", kind: .prCard, runId: run.id, to: store.conversation(for: .bot(bot.id)))
        #expect(!runs.canOpenPR(bot, store: store, github: github), "already in a PR")
        store.apply(.discard, to: run)
        let undone = store.proposeRun(task: "x", crew: .coder, on: bot)
        _ = undone
        #expect(runs.unshippedRuns(bot, store: store).isEmpty)
        let signedOut = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: MemoryKeychain())
        #expect(!runs.canOpenPR(bot, store: store, github: signedOut))
    }
}
