import Foundation
import Testing
@testable import MuxBot

struct MockGitHub: GitHubClient {
    var issues: [GitHubIssue] = []
    var error: (any Error)?
    var files: [String: String] = [:]
    func file(repo: String, path: String) async throws -> Data? {
        files["\(repo)/\(path)"].map { Data($0.utf8) }
    }
    func openIssues(repo: String) async throws -> [GitHubIssue] {
        if let error { throw error }
        return issues
    }
    func issue(repo: String, number: Int) async throws -> GitHubIssue? {
        if let error { throw error }
        return issues.first { $0.number == number }
    }
}

func issue(_ n: Int, _ title: String, labels: [String] = [], pr: Bool = false) -> GitHubIssue {
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
        let turn = FallbackBrain.turn(for: "what do you think of the design?", speaker: bots[0], bots: bots)
        #expect(turn.reply.hasPrefix("I can't answer that without the on-device model"))
    }
}

@Suite(.serialized) @MainActor
struct BotIssueLookupTests {
    private func setUp(issues: [GitHubIssue] = [], error: (any Error)? = nil, repo: Bool = true) -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
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

struct ToolTalkFilterTests {
    @Test func dropsSentencesThatNameATool() {
        let reply = "There are no bugs reported. However, you can use the listOpenIssues tool to check for issues."
        #expect(BotBrain.withoutToolTalk(reply) == "There are no bugs reported.")
    }

    @Test func leavesNormalRepliesAlone() {
        #expect(BotBrain.withoutToolTalk("Two bugs are open. Want me to fix #7?") == "Two bugs are open. Want me to fix #7?")
    }
}

@Suite(.serialized) @MainActor
struct LeadBotIssueTests {
    @Test func leadBotChecksTheNamedBotsRepoAndOffersAHandoff() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "darkmux", instructions: "CLI")
        store.addResource(.repo, "https://github.com/kstrat2001/darkmux", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: [issue(3445, "Crash on empty brief", labels: ["bug"])])
        await brain.send("any bug tickets on darkmux?", in: .lead, store: store)
        let card = (store.conversation(for: .lead).messages ?? []).first { $0.kind == .actionCard }
        #expect(card?.action == .handOff(toId: bot.id, toName: "darkmux", task: "Fix #3445: Crash on empty brief (kstrat2001/darkmux)"))
        let reply = (store.conversation(for: .lead).messages ?? []).filter { $0.role == .assistant && $0.kind == .text }.last?.content ?? ""
        #expect(reply.contains("#3445 Crash on empty brief"))
        #expect(reply.hasSuffix("I'll hand it over."))
    }

    @Test func leadBotReadsEveryRepoWhenItCannotTell() async {
        let store = TestStore.fresh()
        let a = store.add(name: "darkmux", instructions: "CLI")
        store.addResource(.repo, "https://github.com/kstrat2001/darkmux", to: a)
        let b = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: b)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub()
        await brain.send("zzz bug tickets?", in: .lead, store: store)
        let reply = (store.conversation(for: .lead).messages ?? []).filter { $0.role == .assistant }.last?.content ?? ""
        #expect(reply.contains("darkmux (kstrat2001/darkmux)") && reply.contains("humancodereader (kstrat2001/hcr)"), "\(reply)")
    }
}

@Suite(.serialized) @MainActor
struct PreviewRecipeTests {
    let hcrDraft = #"{"schema":"darkmux.preview/draft-1","command":"npm run dev","port":3333,"pages":["/","/pricing"]}"#

    @Test func manifestSummary() throws {
        let m = try JSONDecoder().decode(PreviewManifest.self, from: Data(hcrDraft.utf8))
        #expect(m.summary == "npm run dev on port 3333 · pages /, /pricing")
    }

    @Test func recipeIsReadyWhenTheRepoHasOne() async {
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(files: ["kstrat2001/hcr/.darkmux/preview.json": hcrDraft])
        await brain.runs.recipes.load(for: "kstrat2001/hcr", connection: brain.connection, github: brain.github)
        guard case let .ready(m, fromLocal)? = brain.runs.recipes.recipes["kstrat2001/hcr"] else { Issue.record("expected ready"); return }
        #expect(m.port == 3333)
        #expect(!fromLocal)   // unpaired: GitHub only
    }

    @Test func recipeIsMissingWhenTheFileIsAbsent() async {
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub()
        await brain.runs.recipes.load(for: "kstrat2001/hcr", connection: brain.connection, github: brain.github)
        #expect(brain.runs.recipes.recipes["kstrat2001/hcr"] == .missing)
    }

    @Test func previewURLKindIsGuessedForTailnetAndLocalhost() {
        #expect(ResourceKind.guess(for: "http://mac.tail123.ts.net:8445/") == .previewURL)
        #expect(ResourceKind.guess(for: "http://localhost:3333") == .previewURL)
        #expect(ResourceKind.guess(for: "https://example.com") == .link)
    }

    @Test func aPreviewLinkIsTheBotsOwn() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.previewURL, "http://mac.tail123.ts.net:8445/", to: bot)
        #expect(bot.previewURL?.port == 8445)
    }
}

struct VisualReportTests {
    let bot = BotSummary(id: UUID(), name: "humancodereader", instructions: "Website", state: .ready)

    @Test func describedVisualProblemBecomesACoderFixNotAVerdict() {
        let text = "the Start_a_Project border looks like it has no padding on left and right."
        let turn = FallbackBrain.turn(for: text, speaker: bot, bots: [bot])
        #expect(turn.action == .dispatch(crew: .coder, task: "Fix: \(text)"))
        #expect(turn.reply.hasPrefix("I can't see the preview"))
    }

    @Test func questionsAboutLooksAreNotReports() {
        #expect(!FallbackBrain.isVisualReport("does the border look ok?"))
    }
}

struct FixedByTests {
    private func issue(_ n: Int, _ title: String, pr: Bool = false, body: String? = nil) -> GitHubIssue {
        GitHubIssue(number: n, title: title, pullRequest: pr ? .init() : nil, body: body)
    }

    @Test func closingKeywordsInPRBodies() {
        #expect(issue(9, "Pad", pr: true, body: "Fixes #8.\nAlso closes #3, resolves kstrat2001/hcr#4").fixes == [8, 3, 4])
        #expect(issue(9, "Pad", pr: true, body: "Mentions #8 only").fixes.isEmpty)
        #expect(issue(7, "Not a PR", body: "Fixes #8").fixes.isEmpty)
    }

    @Test func issueLinesNameTheirOpenPR() {
        let all = [issue(9, "Restore side padding", pr: true, body: "Fixes #8."), issue(8, "Start a project box has no gutter")]
        let fixed = IssueQuery.fixedBy(all)
        #expect(fixed[8] == [9])
        #expect(all[1].line(fixedBy: fixed[8] ?? []) == "#8 Start a project box has no gutter (open PR #9 fixes it)")
    }

    @Test func fallbackSkipsIssuesThatAlreadyHaveAPR() {
        let all = [issue(9, "Restore side padding", pr: true, body: "Fixes #8."), issue(8, "No gutter"), issue(5, "Footer")]
        let turn = FallbackBrain.issuesTurn(all, repo: "kstrat2001/hcr", asked: "any open issues?")
        #expect(turn.reply.contains("#8 No gutter (open PR #9 fixes it)"))
        #expect(turn.reply.contains("Fix #5"))
        let onlyFixed = FallbackBrain.issuesTurn(Array(all.prefix(2)), repo: "kstrat2001/hcr", asked: "any open issues?")
        #expect(onlyFixed.action == nil)
        #expect(onlyFixed.reply.contains("PR #9 is open for #8"))
    }

    @Test func lookupLineSaysState() {
        var pr = issue(9, "Restore side padding", pr: true)
        pr.state = "open"
        #expect(pr.statusLine == "#9 PR: Restore side padding — open")
        pr.state = "closed"; pr.pullRequest = .init(mergedAt: "2026-11-07T00:00:00Z")
        #expect(pr.statusLine == "#9 PR: Restore side padding — merged")
    }
}
