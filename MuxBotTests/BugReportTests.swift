import Foundation
import Testing
@testable import MuxBot

@MainActor
final class MockInspector: PageInspecting {
    var result: PageFacts?
    var askedTerms: [String] = []
    /// The bot whose page is on screen; nil stands for whichever bot asks.
    var botOnScreen: UUID?
    init(_ result: PageFacts?) { self.result = result }
    func facts(for terms: [String], bot: UUID?) async -> PageFacts? {
        askedTerms = terms
        if let botOnScreen, botOnScreen != bot { return nil }
        return result
    }
    func snapshotPNG(bot: UUID?) async -> Data? { nil }
}

struct BugReportTests {
    let fact = ElementFact(term: "Start_a_Project", tag: "section", left: 0, right: 0, width: 1091,
                           paddingLeft: "53px", paddingRight: "53px", marginLeft: "0px", marginRight: "0px")

    @Test(arguments: [
        ("the Start_a_Project border looks like it has no padding on left and right.", ["Start_a_Project"]),
        ("the \"Choose your level\" text wraps badly", ["Choose your level"]),
        ("the pricing cards overlap the footer", ["pricing", "cards", "footer"]),
    ])
    func searchTerms(text: String, expected: [String]) {
        #expect(BugReport.searchTerms(in: text) == expected)
    }

    @Test func describesMeasurements() {
        let facts = PageFacts(viewport: 1091, url: "/models", matches: [fact])
        #expect(BugReport.describe(facts) == ["The Start_a_Project box (section) is 0px from the left edge and 0px from the right at 1091px wide; padding 53px / 53px, margin 0px / 0px."])
    }

    @Test func issueURLIsPrefilledAndEncoded() throws {
        let draft = BugReport.draft(from: "the Start_a_Project border has no side margin. It touches the edges.",
                                    facts: PageFacts(viewport: 1091, url: "/models", matches: [fact]), page: nil, repo: "kstrat2001/hcr")
        #expect(draft.title == "The Start_a_Project border has no side margin")
        let url = try #require(draft.issueURL)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.absoluteString.hasPrefix("https://github.com/kstrat2001/hcr/issues/new?"))
        #expect(items.first { $0.name == "title" }?.value == draft.title)
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(body.contains("1. Open /models at 1091px wide"))
        #expect(body.contains("- The Start_a_Project box (section) is 0px from the left edge"))
    }

    @Test func noRepoMeansNoIssueURL() {
        #expect(BugReport.draft(from: "x looks off", facts: nil, page: nil, repo: nil).issueURL == nil)
    }

    @Test(arguments: [
        ("the Start_a_Project border looks like it has no padding on left and right.", true),
        ("the cards overlap the footer on phone", true),
        ("does the border look ok?", false),
        ("fix the footer bugs", false),
    ])
    func visualReportIntent(text: String, isReport: Bool) {
        #expect(FallbackBrain.isVisualReport(text.lowercased()) == isReport)
    }
}

@Suite(.serialized) @MainActor
struct BugFlowTests {
    @Test func describedProblemMeasuresThePageAndPostsABugCard() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let inspector = MockInspector(PageFacts(viewport: 1091, url: "/models", matches: [
            ElementFact(term: "Start_a_Project", tag: "section", left: 0, right: 0, width: 1091,
                        paddingLeft: "53px", paddingRight: "53px", marginLeft: "0px", marginRight: "0px")]))
        brain.pageInspector = inspector
        await brain.send("the Start_a_Project border looks like it has no padding on left and right.", in: .bot(bot.id), store: store)

        #expect(inspector.askedTerms == ["Start_a_Project"])
        let messages = (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }
        let reply = try #require(messages.last { $0.kind == .text && $0.role == .assistant })
        #expect(reply.content.hasPrefix("The Start_a_Project box (section) is 0px from the left edge"))
        #expect(!reply.content.localizedCaseInsensitiveContains("looks good"))
        let card = try #require(messages.last { $0.kind == .bugCard })
        let draft = try JSONDecoder().decode(BugDraft.self, from: Data(card.content.utf8))
        #expect(draft.repo == "kstrat2001/hcr")
        #expect(draft.viewport == 1091)
    }

    @Test func withoutAPreviewItStillDraftsAndSaysItCouldNotMeasure() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        await brain.send("the footer overlaps the cards", in: .bot(bot.id), store: store)
        let messages = store.conversation(for: .bot(bot.id)).messages ?? []
        #expect(messages.contains { $0.content.hasPrefix("I can't see the site and the preview isn't open") })
        #expect(messages.contains { $0.kind == .bugCard })
    }
}
