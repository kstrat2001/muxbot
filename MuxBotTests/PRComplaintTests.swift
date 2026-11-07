import Foundation
import Testing
@testable import MuxBot

/// "PR 9 is still not right" is a report about pull request #9, never a
/// request to list open issues (Kain, 2026-11-07: that sentence offered
/// "Fix #10" instead).
struct PRReferenceTests {
    @Test(arguments: [
        ("PR 9 is still not right", 9),
        ("pr #9 looks off", 9),
        ("PR#9 broke the footer", 9),
        ("pull request 9 is wrong", 9),
        ("#9", 9),
    ])
    func issueNumberReadsPRReferences(text: String, number: Int) {
        #expect(Intent.issueNumber(in: text) == number)
    }

    @Test func kainsSentenceIsNotAnIssuesQuestion() {
        #expect(!FallbackBrain.isIssueQuestion("pr 9 is still not right"))
        #expect(Intent.infer("PR 9 is still not right", hasElement: false) != .issues)
    }

    @Test(arguments: ["are there open PRs?", "any open pr?", "what pull requests are open?", "is there a pr for this?"])
    func askingAboutOpenPRsStillListsThem(question: String) {
        #expect(FallbackBrain.isIssueQuestion(question.lowercased()), "\(question)")
    }

    @Test(arguments: [
        ("PR 9 is still not right", 9),
        ("pr #9 didn't fix it", 9),
        ("PR 9 is still broken on tablet", 9),
        ("PR 9 did not fix the gap", 9),
        ("pull request 9 is wrong", 9),
    ])
    func complaintsAboutAPR(text: String, number: Int) {
        #expect(Intent.prComplaint(in: text)?.number == number, "\(text)")
    }

    @Test(arguments: ["PR 9 looks great", "fix #9", "are there open PRs?", "the footer is wrong"])
    func notComplaintsAboutAPR(text: String) {
        #expect(Intent.prComplaint(in: text) == nil, "\(text)")
    }

    @Test func whatsWrongIsWhatsLeftAfterTheReferenceAndTheComplaint() {
        #expect(Intent.prComplaint(in: "PR 9 is still not right")?.whatsWrong == nil)
        #expect(Intent.prComplaint(in: "pr #9 didn't fix it")?.whatsWrong == nil)
        #expect(Intent.prComplaint(in: "PR 9 didn't fix the gap on tablet")?.whatsWrong == "the gap on tablet")
        #expect(Intent.prComplaint(in: "PR 9 is still broken: the box touches the edges at 820px")?.whatsWrong
                == "the box touches the edges at 820px")
    }
}

@Suite(.serialized) @MainActor
struct PRComplaintFlowTests {
    let nine = PullRequestInfo(number: 9, title: "Restore side padding", merged: true, state: "closed",
                               files: ["inertia/pages/pricing.tsx", "inertia/css/app.css"])

    /// Kain's thread as it was: a finished #10 run and a canceled "Fix PR #9".
    private func setUp(pulls: [PullRequestInfo]? = nil) -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        let ten = store.proposeRun(task: "Fix #10: Tablet sizing looks off (kstrat2001/hcr)", crew: .coder, on: bot)
        store.apply(.approve, to: ten)
        ten.phase = .result
        ten.finishedAt = Date().addingTimeInterval(-60 * 60)
        let old = store.proposeRun(task: "Fix PR #9", crew: .coder, on: bot)
        store.apply(.cancel, to: old)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: [GitHubIssue(number: 10, title: "Tablet sizing looks off", body: "Open /pricing")],
                                  pulls: pulls ?? [nine])
        return (store, bot, brain)
    }

    private func replies(_ store: BotStore, _ bot: Bot) -> [String] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }
            .filter { $0.role == .assistant && $0.kind == .text }.map(\.content)
    }

    private func proposed(_ bot: Bot) -> [BotRun] { (bot.runs ?? []).filter { $0.phase == .proposed } }

    @Test func kainsSentenceAsksWhatsWrongCitingThePR() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("PR 9 is still not right", in: .bot(bot.id), store: store)
        let reply = try #require(replies(store, bot).last)
        #expect(reply.contains("PR #9"), "\(reply)")
        #expect(reply.contains("Restore side padding"))
        #expect(reply.contains("inertia/pages/pricing.tsx") && reply.contains("inertia/css/app.css"))
        #expect(reply.contains("What's still wrong"))
        #expect(!reply.contains("Fix #10"), "never the open-issues list")
        #expect(proposed(bot).isEmpty, "asks first: nothing to approve yet")
        #expect(bot.runs?.count == 2, "no tweak or rerun of an older run")
    }

    @Test func theAnswerBecomesACoderDispatchThatCitesThePR() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("PR 9 is still not right", in: .bot(bot.id), store: store)
        await brain.send("the pricing box still touches the edges at 820px", in: .bot(bot.id), store: store)
        let run = try #require(proposed(bot).first)
        #expect(proposed(bot).count == 1)
        #expect(run.crew == .coder)
        #expect(run.task == "Follow up on PR #9: Restore side padding (kstrat2001/hcr)")
        let brief = try #require(run.brief)
        #expect(brief.contains("PR #9 in kstrat2001/hcr (merged): Restore side padding"), "\(brief)")
        #expect(brief.contains("inertia/pages/pricing.tsx"))
        #expect(brief.contains("What's still wrong: the pricing box still touches the edges at 820px"))
    }

    @Test func sayingWhatsWrongUpFrontProposesTheRunAtOnce() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("PR 9 didn't fix the gap on tablet", in: .bot(bot.id), store: store)
        let run = try #require(proposed(bot).first)
        #expect(run.task == "Follow up on PR #9: Restore side padding (kstrat2001/hcr)")
        #expect(run.brief?.contains("What's still wrong: the gap on tablet") == true)
    }

    @Test func aPRGitHubDoesntKnowIsSaidPlainly() async throws {
        let (store, bot, brain) = setUp(pulls: [])
        await brain.send("PR 9 is still not right", in: .bot(bot.id), store: store)
        #expect(replies(store, bot).last == "I can't find pull request #9 on kstrat2001/hcr.")
        #expect(proposed(bot).isEmpty)
    }

    @Test func thanksIsNotAnAnswer() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("PR 9 is still not right", in: .bot(bot.id), store: store)
        await brain.send("thanks", in: .bot(bot.id), store: store)
        #expect(!(bot.runs ?? []).contains { $0.task.hasPrefix("Follow up on PR #9") })
    }

    @Test func namingAnIssueAfterTheQuestionGoesToThatIssue() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("PR 9 is still not right", in: .bot(bot.id), store: store)
        await brain.send("fix #10", in: .bot(bot.id), store: store)
        #expect(!(bot.runs ?? []).contains { $0.task.hasPrefix("Follow up on PR #9") })
    }

    @Test func anotherKindOfMessageDropsThePendingQuestion() async throws {
        let (store, bot, brain) = setUp()
        await brain.send("PR 9 is still not right", in: .bot(bot.id), store: store)
        await brain.send("issues: anything open?", in: .bot(bot.id), store: store)
        await brain.send("thanks", in: .bot(bot.id), store: store)
        #expect(!(bot.runs ?? []).contains { $0.task.hasPrefix("Follow up on PR #9") })
    }
}

/// The REST client reads a PR's title, merge state and changed files.
@Suite(.serialized)
struct PullRequestLookupTests {
    final class PRStub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var bodies: [String: (Int, String)] = [:]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url!.path + (request.url!.query.map { "?\($0)" } ?? "")
            let (status, body) = Self.bodies[path] ?? (404, "")
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client() -> RESTGitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PRStub.self]
        return RESTGitHubClient(session: URLSession(configuration: config), token: { nil })
    }

    @Test func readsTitleMergeAndFiles() async throws {
        PRStub.bodies = [
            "/repos/kstrat2001/hcr/pulls/9": (200, #"{"number":9,"title":"Restore side padding","state":"closed","merged_at":"2026-11-06T10:00:00Z"}"#),
            "/repos/kstrat2001/hcr/pulls/9/files?per_page=100": (200, #"[{"filename":"inertia/pages/pricing.tsx"},{"filename":"inertia/css/app.css"}]"#),
        ]
        let pr = try #require(try await client().pullRequest(repo: "kstrat2001/hcr", number: 9))
        #expect(pr == PullRequestInfo(number: 9, title: "Restore side padding", merged: true, state: "closed",
                                      files: ["inertia/pages/pricing.tsx", "inertia/css/app.css"]))
    }

    @Test func aMissingPRIsNil() async throws {
        PRStub.bodies = [:]
        #expect(try await client().pullRequest(repo: "kstrat2001/hcr", number: 10) == nil)
    }
}
