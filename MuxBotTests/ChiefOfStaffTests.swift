import Foundation
import SwiftData
import Testing
@testable import MuxBot

/// Mux Bot as chief of staff: it checks before it talks, and it knows what
/// the bots are doing.
@Suite(.serialized) @MainActor
struct CheckBeforeTalkingTests {
    private func setUp() -> (BotStore, BotBrain, Bot, Bot) {
        let store = TestStore.fresh()
        let hcr = store.add(name: "hcr", instructions: "The humancodereader.com website.")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: hcr)
        let dm = store.add(name: "darkmux", instructions: "The darkmux CLI.")
        store.addResource(.repo, "https://github.com/kstrat2001/darkmux", to: dm)
        let brain = BotBrain()
        // The on-device model stays on: these questions must never reach it.
        brain.github = MockGitHub(issues: [
            GitHubIssue(number: 8, title: "No gutter on pricing", labels: [.init(name: "bug")]),
            GitHubIssue(number: 9, title: "Restore side padding", pullRequest: .init(), body: "Fixes #8."),
            GitHubIssue(number: 5, title: "Footer link 404s", labels: [.init(name: "bug")]),
        ])
        return (store, brain, hcr, dm)
    }

    private func lastReply(_ store: BotStore, _ chat: ChatContext) -> String {
        (store.conversation(for: chat).messages ?? []).filter { $0.role == .assistant && $0.kind == .text }
            .max { $0.timestamp < $1.timestamp }?.content ?? ""
    }

    @Test func kainsQuestionIsAnsweredFromGitHub() async {
        let question = "are there any humancodereader bugs to fix?"
        #expect(Intent.infer(question, hasElement: false) == .issues)
        let (store, brain, _, _) = setUp()
        await brain.send(question, in: .lead, store: store)
        let reply = lastReply(store, .lead)
        #expect(reply.contains("#8 No gutter on pricing"), "\(reply)")
        #expect(reply.contains("open PR #9 fixes it"), "\(reply)")
        #expect(reply.contains("#5 Footer link 404s"))
        #expect(!reply.localizedCaseInsensitiveContains("tool"))
    }

    @Test(arguments: ["any bugs?", "what issues are open?", "anything to fix?", "are there open PRs?"])
    func theLeadBotReadsEveryBotsRepoWhenNoneIsNamed(question: String) async {
        let (store, brain, _, _) = setUp()
        await brain.send(question, in: .lead, store: store)
        let reply = lastReply(store, .lead)
        #expect(reply.contains("hcr") && reply.contains("darkmux"), "\(question) → \(reply)")
        #expect(!reply.contains("Which bot's repo"))
    }

    @Test func toolTalkIsStripped() {
        let reply = BotBrain.withoutToolTalk("No bugs in humancodereader. To check, use the listOpenIssues tool.")
        #expect(reply == "No bugs in humancodereader.")
        #expect(BotBrain.withoutToolTalk("I'd need to call a function to check that.").isEmpty == false)
        #expect(!BotBrain.withoutToolTalk("Let me call the GitHub API to check.").localizedCaseInsensitiveContains("api"))
    }
}

@Suite(.serialized) @MainActor
struct TrackAndChaseTests {
    @Test(arguments: ["what's running?", "what needs me?", "what's next?", "status?"])
    func workQuestionsAreAnsweredFromTheRuns(question: String) async {
        let store = TestStore.fresh()
        let hcr = store.add(name: "hcr", instructions: "Site")
        let run = store.proposeRun(task: "Fix #8: gutter", crew: .coder, on: hcr)
        store.apply(.approve, to: run)
        run.startedAt = Date().addingTimeInterval(-5 * 60)
        let brain = BotBrain()
        await brain.send(question, in: .lead, store: store)
        let reply = (store.conversation(for: .lead).messages ?? []).last { $0.role == .assistant }?.content ?? ""
        #expect(reply.contains("hcr"), "\(reply)")
        #expect(reply.contains("Fix #8: gutter"))
        #expect(reply.contains(RunLink.url(for: run).absoluteString), "a link to its card")
        #expect(!reply.contains("can't see the fleet"))
    }

    @Test func theStatusListsEachRunWithItsTimeAndCard() {
        let store = TestStore.fresh()
        let hcr = store.add(name: "hcr", instructions: "Site")
        let dm = store.add(name: "darkmux", instructions: "CLI")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let running = store.proposeRun(task: "Fix #8: gutter", crew: .coder, on: hcr)
        store.apply(.approve, to: running); running.startedAt = now.addingTimeInterval(-7 * 60)
        let waiting = store.proposeRun(task: "Review #12", crew: .reviewer, on: dm)
        let result = store.proposeRun(task: "Fix #5: footer", crew: .coder, on: hcr)
        store.apply(.approve, to: result); store.apply(.finish(summary: "Done."), to: result)
        result.finishedAt = now.addingTimeInterval(-3 * 3600)
        let failed = store.proposeRun(task: "Fix #3", crew: .coder, on: dm)
        store.apply(.approve, to: failed); store.apply(.fail(reason: "Didn't finish: timeout", details: nil), to: failed)
        failed.finishedAt = now.addingTimeInterval(-3600)
        let oldFailure = store.proposeRun(task: "Fix #1", crew: .coder, on: dm)
        store.apply(.approve, to: oldFailure); store.apply(.fail(reason: "x", details: nil), to: oldFailure)
        oldFailure.finishedAt = now.addingTimeInterval(-3 * 86400)

        let text = WorkStatus.summary(runs: [running, waiting, result, failed, oldFailure], now: now)
        #expect(!text.contains("Fix #1"), "failures older than a day drop off")
        #expect(text.contains("Running:\n• hcr: Fix #8: gutter, 7 min"), "\(text)")
        #expect(text.contains("Waiting for your Approve:\n• darkmux: Review #12"), "\(text)")
        #expect(text.contains("Results to Keep or Discard:\n• hcr: Fix #5: footer, waiting 3 h"), "\(text)")
        #expect(text.contains("Didn't finish:\n• darkmux: Fix #3"), "\(text)")
        for run in [running, waiting, result, failed] { #expect(text.contains(RunLink.url(for: run).absoluteString)) }
        #expect(WorkStatus.summary(runs: [], now: now) == "Nothing is running and nothing waits on you.")
    }

    @Test func resultsThatWaitTooLongGetANudge() {
        let store = TestStore.fresh()
        let hcr = store.add(name: "hcr", instructions: "Site")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = store.proposeRun(task: "Fix #5", crew: .coder, on: hcr)
        store.apply(.approve, to: old); store.apply(.finish(summary: "Done."), to: old)
        old.finishedAt = now.addingTimeInterval(-26 * 3600)
        let fresh = store.proposeRun(task: "Fix #6", crew: .coder, on: hcr)
        store.apply(.approve, to: fresh); store.apply(.finish(summary: "Done."), to: fresh)
        fresh.finishedAt = now.addingTimeInterval(-10 * 60)
        let nudges = WorkStatus.nudges(runs: [old, fresh], now: now)
        #expect(nudges.count == 1)
        #expect(nudges.first?.contains("Fix #5") == true)
        #expect(nudges.first?.contains("1 day") == true, "\(nudges)")
    }

    @Test func runLinksRoundTrip() {
        let id = UUID()
        #expect(RunLink.runId(from: RunLink.url(for: id)) == id)
        #expect(RunLink.runId(from: URL(string: "https://github.com/x/y")!) == nil)
    }
}

struct RunLinkLabelTests {
    @Test func runLinksReadAsOpenCard() {
        let id = UUID()
        let a = Linkify.attributed("• hcr: Fix #8, 7 min (\(RunLink.url(for: id).absoluteString))", repo: "kstrat2001/hcr")
        #expect(String(a.characters).hasSuffix("(open card)"))
        #expect(a.runs.contains { $0.link == RunLink.url(for: id) })
    }
}
