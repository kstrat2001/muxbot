import Foundation
import Testing
@testable import MuxBot

struct MockGitHub: GitHubClient {
    var issues: [GitHubIssue] = []
    var error: (any Error)?
    func openIssues(repo: String) async throws -> [GitHubIssue] {
        if let error { throw error }
        return issues
    }
}

private func issue(_ n: Int, _ title: String, labels: [String] = [], pr: Bool = false) -> GitHubIssue {
    GitHubIssue(number: n, title: title, labels: labels.map { .init(name: $0) }, pullRequest: pr ? .init() : nil)
}

struct GitHubIssueParsingTests {
    @Test(arguments: [
        ("https://github.com/kstrat2001/hcr", "kstrat2001/hcr"),
        ("https://github.com/kstrat2001/darkmux.git", "kstrat2001/darkmux"),
        ("github.com/a/b/issues/3", "a/b"),
    ])
    func repoSlug(url: String, slug: String) {
        #expect(GitHubIssue.repoSlug(from: url) == slug)
    }

    @Test func nonGitHubURLsAreNotRepos() {
        #expect(GitHubIssue.repoSlug(from: "~/de-projects/hcr") == nil)
    }

    @Test func decodesRESTIssuesAndMarksPullRequests() throws {
        let json = #"[{"number":7,"title":"Footer link 404s","labels":[{"name":"bug"}]},{"number":8,"title":"Bump deps","labels":[],"pull_request":{"url":"x"}}]"#
        let issues = try JSONDecoder().decode([GitHubIssue].self, from: Data(json.utf8))
        #expect(issues.map(\.number) == [7, 8])
        #expect(issues[0].line == "#7 Footer link 404s [bug]")
        #expect(issues[1].isPullRequest)
    }
}

struct IssuesTurnTests {
    let issues = [issue(3, "Typo on pricing"), issue(7, "Footer link 404s", labels: ["bug"]), issue(8, "Bump deps", pr: true)]

    @Test func bugQuestionListsBugsAndOffersAFix() {
        let turn = FallbackBrain.issuesTurn(issues, repo: "o/r", asked: "do you see any bug tickets we can fix?")
        #expect(turn.reply.contains("#7 Footer link 404s"))
        #expect(!turn.reply.contains("#3"))
        #expect(turn.reply.hasSuffix("Fix #7 with Coder?"))
        #expect(turn.action == .dispatch(crew: .coder, task: "Fix #7: Footer link 404s (o/r)"))
    }

    @Test func noLabeledBugsFallsBackToAllOpenIssues() {
        let turn = FallbackBrain.issuesTurn([issue(3, "Typo on pricing")], repo: "o/r", asked: "any bugs?")
        #expect(turn.reply.contains("#3 Typo on pricing"))
    }

    @Test func pullRequestsOnlyWhenAsked() {
        #expect(!FallbackBrain.issuesTurn(issues, repo: "o/r", asked: "open issues?").reply.contains("#8"))
        #expect(FallbackBrain.issuesTurn(issues, repo: "o/r", asked: "any open prs or issues?").reply.contains("#8 PR: Bump deps"))
    }

    @Test func noIssuesSaysSoWithoutACard() {
        let turn = FallbackBrain.issuesTurn([], repo: "kstrat2001/hcr", asked: "any bug tickets?")
        #expect(turn.reply == "No open bug issues on kstrat2001/hcr.")
        #expect(turn.action == nil)
    }

    @Test func questionsGetAnHonestAnswerNotNoted() {
        let bots = [BotSummary(id: UUID(), name: "humancodereader", instructions: "Website", state: .ready)]
        let turn = FallbackBrain.turn(for: "what do you think of the design?", speaker: bots[0], bots: bots, fleet: .sample)
        #expect(turn.reply.hasPrefix("I can't answer that without the on-device model"))
    }
}

@Suite(.serialized) @MainActor
struct BotIssueLookupTests {
    private func setUp(issues: [GitHubIssue] = [], error: (any Error)? = nil, repo: Bool = true) -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        if repo { store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot) }
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: issues, error: error)
        return (store, bot, brain)
    }

    private func lastReply(_ store: BotStore, _ bot: Bot) -> String? {
        (store.conversation(for: .bot(bot.id)).messages ?? [])
            .filter { $0.role == .assistant && $0.kind == .text }
            .max { $0.timestamp < $1.timestamp }?.content
    }

    @Test func askingForBugTicketsReadsGitHubAndProposesAFix() async {
        let (store, bot, brain) = setUp(issues: [issue(7, "Footer link 404s", labels: ["bug"])])
        await brain.send("Do you see any bug tickets we can fix?", in: .bot(bot.id), store: store)
        #expect(lastReply(store, bot)?.contains("Open on kstrat2001/hcr") == true)
        #expect(bot.runs?.first?.task == "Fix #7: Footer link 404s (kstrat2001/hcr)")
        #expect(bot.runs?.first?.phase == .proposed)
    }

    @Test func gitHubErrorsAreReportedNotHidden() async {
        let (store, bot, brain) = setUp(error: GitHubError(status: 403))
        await brain.send("any open issues?", in: .bot(bot.id), store: store)
        #expect(lastReply(store, bot)?.contains("rate limit") == true)
        #expect(bot.runs?.isEmpty ?? true)
    }

    @Test func noRepoAsksForOne() async {
        let (store, bot, brain) = setUp(repo: false)
        await brain.send("any bug tickets?", in: .bot(bot.id), store: store)
        #expect(lastReply(store, bot)?.hasPrefix("I don't have a GitHub repo yet") == true)
    }
}
