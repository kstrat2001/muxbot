import Foundation
import Testing
@testable import MuxBot

/// Visual issues are measured in the app before a dispatch: the page at the
/// issue's width (or the device presets) and at desktop, with layout facts
/// read by script. No model judges what it sees (Kain's pick, 2026-11-07).

/// Issue #10 as filed (Mux Bot's own draft, with a screenshot).
let issueTen = GitHubIssue(number: 10, title: "Tablet sizing looks off", body: """
    **What's wrong**
    tablet sizing looks off. the animated code gets pushed off to the right by the typing animation  next to >, and sometimes the text wraps down to the next line

    **Steps**
    1. Open / at 820px wide
    2. Look at `div#app > div.layout > main > section.hero.container:nth-of-type(1)`

    **Expected**
    Adjust the animation timing to ensure the text wraps correctly and the animation does not push the content off-screen.

    <img width="746" height="772" alt="Image" src="https://github.com/user-attachments/assets/364c" />
    """)

/// What the hcr home page measures at 820px: a 2-column hero 380px wider
/// than the screen, and one @media rule that stops at 768px.
func overflowingAt820() -> LayoutFacts {
    LayoutFacts(viewport: 820, scrollWidth: 1200, clientWidth: 820,
                wide: [.init(selector: "section.hero.container", width: 1200, right: 1200),
                       .init(selector: "div.scanning-visual", width: 560, right: 1180)],
                media: [.init(media: "(max-width: 768px)", matches: false, selectors: [".container", "header .container"], source: "/inertia/css/app.css")],
                sections: [.init(selector: "section.hero.container", width: 1200, left: 0, display: "grid", columns: 2,
                                 paddingLeft: "20px", paddingRight: "20px", fontSize: "16px", maxWidth: "1200px")])
}

func fitsAt(_ width: Int) -> LayoutFacts {
    LayoutFacts(viewport: width, scrollWidth: width, clientWidth: width, wide: [],
                media: [.init(media: "(max-width: 768px)", matches: width <= 768, selectors: [".container"], source: "/inertia/css/app.css")],
                sections: [.init(selector: "section.hero.container", width: min(width, 1200), left: 0, display: "grid", columns: width <= 768 ? 1 : 2,
                                 paddingLeft: "20px", paddingRight: "20px", fontSize: "16px", maxWidth: "1200px")])
}

@MainActor
final class MockProbe: LayoutProbing {
    var facts: [Int: LayoutFacts]
    var asked: [(url: URL, widths: [Int])] = []
    init(_ facts: [Int: LayoutFacts]) { self.facts = facts }
    func measure(url: URL, widths: [Int]) async -> [LayoutFacts] {
        asked.append((url, widths))
        return widths.compactMap { facts[$0] }
    }
}

struct LayoutMeasureTests {
    @Test func visualIssuesAreThoseWithAScreenshotOrLayoutWords() {
        #expect(LayoutMeasure.isVisual(issueTen))
        #expect(LayoutMeasure.isVisual(GitHubIssue(number: 1, title: "Footer padding is gone", body: "Open /pricing")))
        #expect(!LayoutMeasure.isVisual(GitHubIssue(number: 2, title: "Typo in the README", body: "Open /about; `p.lead` says teh")))
    }

    @Test func theIssuesWidthWhenItsAPresetPlusDesktop() {
        #expect(LayoutMeasure.widths(forViewport: 820) == [820, 1440])
        #expect(LayoutMeasure.widths(forViewport: 390) == [390, 1440])
        #expect(LayoutMeasure.widths(forViewport: 700) == [390, 768, 820, 1024, 1440])
        #expect(LayoutMeasure.widths(forViewport: nil) == [390, 768, 820, 1024, 1440])
    }

    @Test func measuredLinesSayWhatTheNumbersSay() {
        let m = LayoutMeasure.summarize([overflowingAt820(), fitsAt(1440)], focus: 820)
        #expect(m.lines.contains("At 820px: the page is 380px wider than the screen (scrollWidth 1200)."), "\(m.lines)")
        #expect(m.lines.contains("At 820px: wider than the screen: section.hero.container (1200px), div.scanning-visual (560px, right edge at 1180px)."))
        #expect(m.lines.contains("At 820px: section.hero.container is a 2-column grid, max-width 1200px, font 16px."))
        #expect(m.lines.contains("At 820px: no @media rule matches; the only one is (max-width: 768px) in inertia/css/app.css."))
        #expect(m.lines.contains("At 1440px: fits; nothing is wider than the screen."))
        #expect(m.doneWhen == "at 820px nothing is wider than the screen, and 1440px looks the same as now.")
        #expect(m.likelyFile == "inertia/css/app.css")
        #expect(m.foundProblem)
    }

    @Test func zeroPaddingAtThePageEdgeIsAProblem() {
        var f = fitsAt(820)
        f.sections[0].paddingLeft = "0px"; f.sections[0].paddingRight = "0px"
        f.sections[0].textLeft = 0; f.sections[0].textRight = 820
        let m = LayoutMeasure.summarize([f], focus: 820)
        #expect(m.lines.contains("At 820px: section.hero.container's text touches the page edges (0px side padding)."), "\(m.lines)")
        #expect(m.doneWhen == "at 820px section.hero.container keeps side padding.")
        #expect(m.foundProblem)
    }

    /// hcr's real home page at 820px (2026-11-07): full-width sections with
    /// 0px padding whose inner .container keeps the text 20px in, and Vite
    /// listing app.css twice (by URL and by absolute path).
    @Test func realHcrAt820HasNoEdgeProblemAndOneMediaRule() {
        let rule = LayoutFacts.Media(media: "(max-width: 768px)", matches: false, selectors: [":root", ".container"], source: "/inertia/css/app.css")
        var twin = rule
        twin.source = "/Users/me/.darkmux/worktrees/hcr-site/inertia/css/app.css"
        let header = LayoutFacts.Section(selector: "header.header", width: 820, left: 0, display: "block", columns: nil,
                                         paddingLeft: "0px", paddingRight: "0px", fontSize: "16px", maxWidth: "none",
                                         textLeft: 20, textRight: 800)
        let f = LayoutFacts(viewport: 820, scrollWidth: 820, clientWidth: 820, wide: [], media: [rule, twin], sections: [header])
        let m = LayoutMeasure.summarize([f], focus: 820)
        #expect(!m.foundProblem, "\(m.lines)")
        #expect(m.lines.contains("At 820px: no @media rule matches; the only one is (max-width: 768px) in inertia/css/app.css."), "\(m.lines)")
        #expect(m.likelyFile == "inertia/css/app.css")
    }

    @Test func textAtThePageEdgeIsAProblem() {
        let bare = LayoutFacts.Section(selector: "section.cta", width: 820, left: 0, display: "block", columns: nil,
                                       paddingLeft: "0px", paddingRight: "0px", fontSize: "16px", maxWidth: "none",
                                       textLeft: 0, textRight: 820)
        let m = LayoutMeasure.summarize([LayoutFacts(viewport: 820, scrollWidth: 820, clientWidth: 820, wide: [], media: [], sections: [bare])], focus: 820)
        #expect(m.lines.contains("At 820px: section.cta's text touches the page edges (0px side padding)."), "\(m.lines)")
        #expect(m.foundProblem)
    }

    @Test func aPageThatMeasuresFineIsNotAProblem() {
        let m = LayoutMeasure.summarize([fitsAt(820), fitsAt(1440)], focus: 820)
        #expect(!m.foundProblem)
        #expect(m.doneWhen == nil)
    }
}

@Suite(.serialized) @MainActor
struct MeasureBeforeDispatchTests {
    private func setUp(_ issues: [GitHubIssue], probe: MockProbe?, preview: Bool = true) -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        if preview { store.addResource(.previewURL, "http://127.0.0.1:5999/", to: bot) }
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: issues)
        brain.layoutProbe = probe
        return (store, bot, brain)
    }

    private func lastReply(_ store: BotStore, _ bot: Bot) -> String {
        (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }
            .last { $0.role == .assistant && $0.kind == .text }?.content ?? ""
    }

    @Test(arguments: ["fix #10", "any open issues?"])
    func issueTenIsMeasuredAt820AndDesktopBeforeTheCard(message: String) async throws {
        let probe = MockProbe([820: overflowingAt820(), 1440: fitsAt(1440)])
        let (store, bot, brain) = setUp([issueTen], probe: probe)
        await brain.send(message, in: .bot(bot.id), store: store)
        #expect(probe.asked.count == 1)
        #expect(probe.asked.first?.widths == [820, 1440])
        #expect(probe.asked.first?.url.absoluteString == "http://127.0.0.1:5999/")
        let run = try #require(bot.runs?.first)
        #expect(run.phase == .proposed)
        let brief = try #require(run.brief)
        #expect(brief.contains("Measured in the preview:"), "\(brief)")
        #expect(brief.contains("- At 820px: the page is 380px wider than the screen (scrollWidth 1200)."))
        #expect(brief.contains("Likely file: inertia/css/app.css"))
        #expect(brief.contains("Done when: at 820px nothing is wider than the screen, and 1440px looks the same as now."))
        #expect(LayoutMeasure.measuredLines(in: brief).count >= 3, "the card shows them before Approve")
    }

    @Test func aNonVisualIssueIsNotMeasured() async throws {
        let probe = MockProbe([:])
        let typo = GitHubIssue(number: 2, title: "Typo in the README", body: "Open /about; `p.lead` says teh")
        let (store, bot, brain) = setUp([typo], probe: probe)
        await brain.send("fix #2", in: .bot(bot.id), store: store)
        #expect(probe.asked.isEmpty)
        #expect(bot.runs?.first?.brief?.contains("Measured") == false)
    }

    @Test func withoutAPreviewItSaysSoAndStillOffersTheRun() async throws {
        let probe = MockProbe([:])
        let (store, bot, brain) = setUp([issueTen], probe: probe, preview: false)
        await brain.send("fix #10", in: .bot(bot.id), store: store)
        #expect(probe.asked.isEmpty)
        let brief = try #require(bot.runs?.first?.brief)
        #expect(brief.contains("Not measured: the preview isn't running."), "\(brief)")
    }

    @Test func nothingMeasuredWrongAndNoExpectedAsksOneQuestionFirst() async throws {
        let vague = GitHubIssue(number: 12, title: "Tablet layout looks off", body: "**What's wrong**\nlooks off\n\n**Steps**\n1. Open / at 820px wide\n2. Look at `section.hero`")
        let probe = MockProbe([820: fitsAt(820), 1440: fitsAt(1440)])
        let (store, bot, brain) = setUp([vague], probe: probe)
        await brain.send("fix #12", in: .bot(bot.id), store: store)
        #expect(bot.runs?.isEmpty ?? true, "asks first")
        let question = lastReply(store, bot)
        #expect(question.contains("At 820px I measured nothing wider than the screen"), "\(question)")
        #expect(question.hasSuffix("What should change?"))
        await brain.send("stack the hero into one column", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        #expect(run.task == "Fix #12: Tablet layout looks off (kstrat2001/hcr)")
        #expect(run.brief?.contains("What should change: stack the hero into one column") == true, "\(run.brief ?? "")")
        #expect(run.brief?.contains("Measured in the preview:") == true)
    }
}

/// The real probe, offscreen, on a page given as HTML (no network).
@Suite(.serialized) @MainActor
struct WebLayoutProbeTests {
    let html = """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"><style>
        body { margin: 0 }
        .hero { display: grid; grid-template-columns: 1fr 1fr; width: 1200px; padding: 0 20px; font-size: 16px }
        @media (max-width: 768px) { .hero { display: block; width: auto } }
        </style></head><body><main><section class="hero"><div>left</div><div>right</div></section></main></body></html>
        """

    @Test func readsOverflowGridAndMediaRulesAtTheGivenWidth() async throws {
        let probe = WebLayoutProbe()
        let wide = try #require(await probe.measure(html: html, width: 820))
        #expect(wide.viewport == 820)
        #expect(wide.scrollWidth >= 1240, "\(wide.scrollWidth)")
        #expect(wide.wide.first?.selector == "section.hero", "\(wide)")
        #expect(wide.media.count == 1)
        #expect(wide.media.first?.matches == false)
        #expect(wide.sections.first { $0.selector == "section.hero" }?.columns == 2)
        let phone = try #require(await probe.measure(html: html, width: 390))
        #expect(phone.media.first?.matches == true)
        #expect(phone.scrollWidth <= 390, "\(phone.scrollWidth)")
    }
}
