import Foundation
import Testing
@testable import MuxBot

/// A dispatch offered from the open-issues list carries the issue's brief,
/// never a bare title (Fix #10 went out as "Fix #10: Tablet sizing looks off").
@Suite(.serialized) @MainActor
struct IssuesListBriefTests {
    /// Issue #10 as filed (Mux Bot's own draft).
    let ten = GitHubIssue(number: 10, title: "Tablet sizing looks off", body: """
        **What's wrong**
        tablet sizing looks off. the animated code gets pushed off to the right by the typing animation  next to >, and sometimes the text wraps down to the next line

        **Steps**
        1. Open / at 820px wide
        2. Look at `div#app > div.layout > main > section.hero.container:nth-of-type(1)`

        **Expected**
        Adjust the animation timing to ensure the text wraps correctly and the animation does not push the content off-screen.
        """)

    private func setUp(_ issues: [GitHubIssue]) -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: issues)
        return (store, bot, brain)
    }

    @Test func theOfferedFixCarriesTheIssueBrief() async throws {
        let (store, bot, brain) = setUp([ten])
        await brain.send("any open issues?", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        #expect(run.task == "Fix #10: Tablet sizing looks off (kstrat2001/hcr)")
        let brief = try #require(run.brief)
        #expect(brief.contains("Page: / (at 820px wide)"), "\(brief)")
        #expect(brief.contains("Element: div#app > div.layout > main > section.hero.container:nth-of-type(1)"))
    }

    @Test func anIssueThatDoesntSayWhereIsAskedAboutNotDispatched() async throws {
        let (store, bot, brain) = setUp([GitHubIssue(number: 11, title: "Something looks off", body: "it looks weird")])
        await brain.send("any open issues?", in: .bot(bot.id), store: store)
        #expect(bot.runs?.isEmpty ?? true)
        let reply = (store.conversation(for: .bot(bot.id)).messages ?? []).last { $0.role == .assistant }?.content ?? ""
        #expect(reply.contains("#11 doesn't say where"), "\(reply)")
        #expect(!reply.contains("with Coder?"))
    }
}
