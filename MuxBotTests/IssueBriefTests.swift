import Foundation
import Testing
@testable import MuxBot

/// The body Mux Bot's own bug drafts produce (as in kstrat2001/hcr#8).
private let draftedBody = """
**What's wrong**
no padding on left/right of the border

**Steps**
1. Open /pricing at 681px wide
2. Look at `div.layout > main > section.container > div:nth-of-type(2) > div`

**Expected**
The box keeps a side gutter at narrow widths.

**Page facts (measured in the Mux Bot preview)**
- The > Start_a_Project box (div) is 0px from the left edge and 0px from the right at 681px wide; padding 32px / 32px, margin 0px / 0px.

**Screenshot:** paste below.
"""

struct IssueBriefParsingTests {
    @Test func readsPageSelectorFactsAndExpectedFromABugDraft() throws {
        let parts = IssueBrief.parse(draftedBody)
        #expect(parts.page == "/pricing")
        #expect(parts.viewport == 681)
        #expect(parts.selector == "div.layout > main > section.container > div:nth-of-type(2) > div")
        #expect(parts.expected == "The box keeps a side gutter at narrow widths.")
        #expect(parts.facts.first?.hasPrefix("The > Start_a_Project box (div) is 0px from the left edge") == true)
        #expect(parts.problem == "no padding on left/right of the border")
    }

    @Test func plainIssuesYieldWhatTheyHave() {
        let parts = IssueBrief.parse("The footer links overlap on /about when the window is narrow.")
        #expect(parts.page == "/about")
        #expect(parts.selector == nil)
    }

    @Test func likelyFileForAnInertiaPage() {
        #expect(IssueBrief.likelyFile(forPage: "/pricing", pattern: "inertia/pages/{page}.tsx") == "inertia/pages/pricing.tsx")
        #expect(IssueBrief.likelyFile(forPage: "/", pattern: "inertia/pages/{page}.tsx") == "inertia/pages/home.tsx")
        #expect(IssueBrief.likelyFile(forPage: nil, pattern: "inertia/pages/{page}.tsx") == nil)
    }
}

struct IssueBriefCompositionTests {
    @Test func briefIsCompactAndComplete() throws {
        let issue = GitHubIssue(number: 8, title: "No padding on left/right of the border", body: draftedBody)
        let brief = try #require(IssueBrief.compose(issue: issue, repo: "kstrat2001/hcr", crew: .coder, pageFile: "inertia/pages/{page}.tsx"))
        #expect(brief.hasPrefix("Fix GitHub issue #8 in kstrat2001/hcr: No padding on left/right of the border."))
        #expect(brief.contains("Page: /pricing (at 681px wide)"))
        #expect(brief.contains("Element: div.layout > main > section.container > div:nth-of-type(2) > div"))
        #expect(brief.contains("Likely file: inertia/pages/pricing.tsx"))
        #expect(brief.contains("Expected: The box keeps a side gutter at narrow widths."))
        #expect(brief.contains("Done when:"))
        #expect(!brief.contains("Screenshot"))       // no noise for the model
        #expect(brief.count < 1500)
    }

    @Test func noPageAndNoElementMeansAskFirst() {
        let issue = GitHubIssue(number: 9, title: "Looks off", body: "Something about the layout feels wrong.")
        #expect(IssueBrief.compose(issue: issue, repo: "o/r", crew: .coder) == nil)
    }
}

@Suite(.serialized) @MainActor
struct IssueDispatchFlowTests {
    private func setUp(_ issue: GitHubIssue) -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: [issue])
        brain.recipes["kstrat2001/hcr"] = .ready(PreviewManifest(command: "npm run dev", pageFile: "inertia/pages/{page}.tsx"), fromLocalCopy: false)
        return (store, bot, brain)
    }

    @Test func fixIssueWithDetailsGetsACardCarryingTheBrief() async throws {
        let (store, bot, brain) = setUp(GitHubIssue(number: 8, title: "No padding on left/right of the border", body: draftedBody))
        await brain.send("fix #8", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        #expect(run.brief?.contains("Likely file: inertia/pages/pricing.tsx") == true)
    }

    @Test func fixIssueWithoutPageOrElementAsksInsteadOfDispatching() async {
        let (store, bot, brain) = setUp(GitHubIssue(number: 9, title: "Looks off", body: "Something feels wrong."))
        await brain.send("fix #9", in: .bot(bot.id), store: store)
        #expect(bot.runs?.isEmpty ?? true)
        let reply = (store.conversation(for: .bot(bot.id)).messages ?? []).last { $0.role == .assistant }?.content ?? ""
        #expect(reply.contains("Which page"))
    }
}
