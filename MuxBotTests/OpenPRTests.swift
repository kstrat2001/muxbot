import Foundation
import Testing
@testable import MuxBot

@Suite(.serialized) @MainActor
struct OpenPRTests {
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
    /// Review & merge keys on darkmux's status (muxbot#144): any change the
    /// main version lacks, a run's or not (a file you approved, a hand edit).
    @Test func reviewShowsWhenDarkmuxReportsPendingChanges() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        bot.workspaceName = "hcr-ws"
        let keychain = MemoryKeychain(); keychain.items[GitHubAuth.tokenKey] = "ghu_abc"
        let github = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain)
        let runs = RunCoordinator()
        let pending = Counter()
        runs.gitStatusSource = { _ in
            .init(branch: "mux/hcr-1", head: "h", origin: "github.com/kstrat2001/hcr", defaultBranch: "main", base: "b0",
                  pending: pending.count, upstream: nil, ahead: nil, behind: nil, behindMain: 0, dirty: false, busy: nil)
        }
        #expect(!runs.canOpenPR(bot, store: store, github: github), "nothing read from darkmux yet")
        await runs.refreshTaskStatus(bot)
        #expect(!runs.canOpenPR(bot, store: store, github: github), "nothing pending")
        pending.add()
        await runs.refreshTaskStatus(bot)
        #expect(runs.canOpenPR(bot, store: store, github: github), "a change with no run, such as an approved file")
        LocalBotState.shared.update(bot.id) { $0.review = TaskReview.State(number: 12, url: URL(string: "https://github.com/kstrat2001/hcr/pull/12")!, title: "x") }
        #expect(!runs.canStartReview(bot, store: store, github: github), "already in review")
        LocalBotState.shared.update(bot.id) { $0.review = nil }
        ModelSettingsStore.shared.setPendingRepo("kstrat2001/hcr", bot: bot.id)
        #expect(!runs.canOpenPR(bot, store: store, github: github), "still being put on GitHub")
        ModelSettingsStore.shared.setPendingRepo(nil, bot: bot.id)
        let signedOut = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: MemoryKeychain())
        #expect(!runs.canOpenPR(bot, store: store, github: signedOut))
    }
}
