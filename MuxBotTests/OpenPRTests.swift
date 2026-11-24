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
    @Test func changesFromDarkmuxDecode() throws {
        let json = #"{"base":"b0b0","base_branch":"main","head":"h1h1","branch":"mux/hcr-3cfe8f","files":[{"path":"a.txt","mode":"100644","content":"YQ=="},{"path":"gone.txt","deleted":true}]}"#
        let c = try JSONDecoder().decode(DarkmuxClient.Changes.self, from: Data(json.utf8))
        #expect(c.baseBranch == "main")
        #expect(c.files[1].deleted == true)
    }

    /// The branch goes to GitHub through darkmux; the app only opens the PR,
    /// from that branch into the main one.
    @Test func thePRIsOpenedFromTheBranchDarkmuxPushed() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /repos/kstrat2001/hcr/pulls", 201, #"{"number":12,"html_url":"https://github.com/kstrat2001/hcr/pull/12"}"#)
        let pr = try await GitHubPR(session: GitHubStub.session, token: "t")
            .open(repo: "kstrat2001/hcr", head: "mux/hcr-3cfe8f", base: "main", title: "x", body: "y")
        #expect(pr.number == 12)
        #expect(GitHubStub.seen.map(\.path) == ["/repos/kstrat2001/hcr/pulls"], "no blobs, trees, commits or refs")
    }

    @Test func aPRAlreadyOpenForTheBranchIsFound() async throws {
        GitHubStub.reset()
        GitHubStub.on("POST /repos/kstrat2001/hcr/pulls", 422, #"{"message":"Validation Failed","errors":[{"message":"A pull request already exists for kstrat2001:mux/hcr-3cfe8f."}]}"#)
        GitHubStub.on("GET /repos/kstrat2001/hcr/pulls", 200, #"[{"number":9,"html_url":"https://github.com/kstrat2001/hcr/pull/9"}]"#)
        let pr = try await GitHubPR(session: GitHubStub.session, token: "t")
            .open(repo: "kstrat2001/hcr", head: "mux/hcr-3cfe8f", base: "main", title: "x", body: "y")
        #expect(pr.number == 9)
    }

    @Test func aRepoTheAppCantWriteToSaysSo() async {
        GitHubStub.reset()
        GitHubStub.on("POST /repos/kstrat2001/hcr/pulls", 404, #"{"message":"Not Found"}"#)
        do {
            _ = try await GitHubPR(session: GitHubStub.session, token: "t")
                .open(repo: "kstrat2001/hcr", head: "mux/hcr-3cfe8f", base: "main", title: "x", body: "y")
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
