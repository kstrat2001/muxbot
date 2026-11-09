import CoreGraphics
import Foundation
import Testing
@testable import MuxBot

/// The device frame always fits the panel it's drawn in: a scale kept from
/// a wider panel (while a resize settles) never clips the page on the right.
struct PreviewFrameFitTests {
    private let wide = CGSize(width: 810, height: 1200)
    /// About the panel in Kain's screenshot, where the phone was clipped.
    private let narrow = CGSize(width: 365, height: 900)

    private func fits(_ layout: PreviewViewport.Layout, in panel: CGSize, _ label: String) {
        let shownWidth = layout.width * layout.scale
        let origin = layout.origin(in: panel)
        #expect(origin.x >= 0, "\(label): starts inside the panel, x \(origin.x)")
        #expect(origin.x + shownWidth <= panel.width + 0.5, "\(label): ends inside the panel, \(origin.x + shownWidth) of \(panel.width)")
    }

    @Test(arguments: [PreviewViewport.phone, .smallTablet, .tablet])
    func aDeviceShrinksToAPanelThatGotNarrower(_ device: PreviewViewport) {
        let stale = device.layout(in: wide)
        let shown = device.shown(settled: stale, in: narrow)
        fits(shown, in: narrow, device.rawValue)
        #expect(shown == device.layout(in: narrow), "\(device.rawValue): the panel's current fit")
        let origin = shown.origin(in: narrow)
        #expect(abs(origin.x - (narrow.width - shown.width * shown.scale) / 2) < 0.5, "centered")
    }

    @Test(arguments: [PreviewViewport.phone, .smallTablet, .tablet])
    func aDeviceGrowsBackWhenThePanelWidens(_ device: PreviewViewport) {
        let stale = device.layout(in: narrow)
        #expect(device.shown(settled: stale, in: wide) == device.layout(in: wide))
    }

    @Test func desktopNeverRunsPastThePanelWhileItSettles() {
        let stale = PreviewViewport.desktop.layout(in: CGSize(width: 1600, height: 900))
        let shown = PreviewViewport.desktop.shown(settled: stale, in: narrow)
        fits(shown, in: narrow, "desktop")
        #expect(shown.width == 1440, "still laid out at desktop width")
    }

    @Test func desktopKeepsItsSettledHeightWhileItFits() {
        let settled = PreviewViewport.desktop.layout(in: CGSize(width: 720, height: 900))
        let shown = PreviewViewport.desktop.shown(settled: settled, in: CGSize(width: 730, height: 880))
        #expect(shown == settled, "a small resize doesn't re-lay out the page's height on every frame")
    }

    @Test func fitIsThePanel() {
        #expect(PreviewViewport.fit.shown(settled: nil, in: narrow) == PreviewViewport.Layout(width: 365, height: 900, scale: 1))
    }

    @Test func kainsPanelWasNarrowerThanAPhone() {
        // 365pt of panel leaves 333pt for the 390pt phone: it has to scale.
        let shown = PreviewViewport.phone.shown(settled: PreviewViewport.phone.layout(in: wide), in: narrow)
        #expect(shown.scale < 1)
        #expect(abs(shown.scale - 333.0 / 390.0) < 0.001)
    }
}

/// "Cut off" when the page fits at every width: the bot says so plainly and
/// offers a reload, never a bug or a Fix it now.
@Suite(.serialized) @MainActor
struct PageFitsTests {
    private func fitting(_ width: Int) -> LayoutFacts {
        LayoutFacts(viewport: width, scrollWidth: width, clientWidth: width, wide: [],
                    media: [.init(media: "(max-width: 640px)", matches: width <= 640, selectors: [".feature-grid"], source: "/workspace/src/styles.css")],
                    sections: [.init(selector: "section.features", width: width, left: 0, display: "grid", columns: 1,
                                     paddingLeft: "16px", paddingRight: "16px", fontSize: "16px", maxWidth: "none",
                                     textLeft: 16, textRight: width - 16)])
    }

    private func overflowing(_ width: Int) -> LayoutFacts {
        var f = fitting(width)
        f.scrollWidth = width + 32
        f.wide = [.init(selector: "div.feature", width: width + 32, right: width + 32)]
        return f
    }

    private let card = PickedElement(label: "Fast", selector: "section.features > div.feature", tag: "div",
                                     url: "/", viewport: 422, left: 16, right: 16, width: 390, height: 160,
                                     paddingLeft: "24px", paddingRight: "24px", marginLeft: "0px", marginRight: "0px", x: 16, y: 900)

    private func send(_ text: String, probe: MockProbe) async -> (BotStore, Bot) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "Site")
        store.addResource(.repo, "https://github.com/kstrat2001/muxbot-start-check-2", to: bot)
        store.addResource(.previewURL, "http://127.0.0.1:5999/", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.layoutProbe = probe
        await brain.send(text, in: .bot(bot.id), store: store, element: card)
        return (store, bot)
    }

    private func messages(_ store: BotStore, _ bot: Bot) -> [ChatMessage] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    @Test func cutOffButFitsEverywhereIsNoBug() async throws {
        let probe = MockProbe([422: fitting(422), 390: fitting(390), 768: fitting(768), 1440: fitting(1440)])
        let (store, bot) = await send("I still see the borders around each feature card off the screen to the right", probe: probe)
        let all = messages(store, bot)
        #expect(!all.contains { $0.kind == .bugCard }, "no bug drafted, so no Fix it now")
        let note = try #require(all.last { $0.kind == .guideCard })
        #expect(note.guideCard == .pageFits(text: BugReport.pageFitsText))
        #expect(BugReport.pageFitsText == "The page itself fits at every width I checked. If the preview looks cut off, it may be the preview panel.")
        #expect(bot.runs?.isEmpty ?? true)
    }

    @Test func realOverflowIsStillABug() async throws {
        let probe = MockProbe([422: overflowing(422), 390: overflowing(390), 768: fitting(768), 1440: fitting(1440)])
        let (store, bot) = await send("the feature cards are cut off on the right", probe: probe)
        #expect(messages(store, bot).contains { $0.kind == .bugCard })
    }

    @Test func aComplaintThatIsntAboutOverflowIsStillABug() async throws {
        let probe = MockProbe([422: fitting(422), 390: fitting(390), 768: fitting(768), 1440: fitting(1440)])
        let (store, bot) = await send("the borders look too thin", probe: probe)
        #expect(messages(store, bot).contains { $0.kind == .bugCard })
    }

    @Test(arguments: ["off the screen to the right", "the cards are cut off", "it overflows", "scrolls sideways", "clipped on the right", "wider than the screen"])
    func overflowComplaints(text: String) {
        #expect(BugReport.isOverflowComplaint(text), "\(text)")
    }

    @Test(arguments: ["the borders look too thin", "make it bigger", "the font is wrong"])
    func notOverflowComplaints(text: String) {
        #expect(!BugReport.isOverflowComplaint(text), "\(text)")
    }
}

/// A bug card leads with one plain sentence; the measurements are behind
/// Show details, and Coder's brief still gets all of them.
@Suite(.serialized) @MainActor
struct PlainBugCardTests {
    @Test func theMeasuredProblemIsOnePlainSentence() {
        var f = LayoutFacts(viewport: 390, scrollWidth: 422, clientWidth: 390,
                            wide: [.init(selector: "div.feature", width: 422, right: 422)], media: [], sections: [])
        f.media = [.init(media: "(max-width: 640px)", matches: true, selectors: [".feature"], source: "/workspace/src/styles.css")]
        let m = LayoutMeasure.summarize([f], focus: 390)
        #expect(m.plain == "At 390px the page is wider than the screen, so it scrolls sideways.")
        #expect(m.lines.contains { $0.contains("@media") }, "the technical lines are still measured")
    }

    @Test func theCardShowsThePlainSentenceAndHidesTheRest() {
        let draft = BugDraft(title: "Cards off the screen", described: "cards off the screen", page: "/", viewport: 390,
                             facts: ["At 390px: @media (max-width: 640px) in workspace/src/styles.css applies.", "At 390px: the page is 32px wider than the screen (scrollWidth 422)."],
                             repo: "kstrat2001/site", plain: "At 390px the page is wider than the screen, so it scrolls sideways.")
        #expect(draft.headline == "At 390px the page is wider than the screen, so it scrolls sideways.")
        #expect(!draft.headline.contains("@media") && !draft.headline.contains("styles.css"))
        #expect(draft.details == draft.facts.joined(separator: "\n"))
        #expect(draft.body.contains("@media (max-width: 640px) in workspace/src/styles.css"), "the brief and the issue keep every measurement")
    }

    @Test func aDraftWithoutAMeasuredProblemSaysSoPlainly() {
        let draft = BugDraft(title: "Thin borders", described: "the borders look too thin", page: "/", viewport: 390,
                             facts: ["At 390px: fits; nothing is wider than the screen."], repo: nil)
        #expect(draft.headline == "Drafted from your description; the measurements are in the details.")
    }

    @Test func anOldDraftWithoutThePlainLineStillDecodes() throws {
        let json = #"{"title":"t","described":"d","page":"/","facts":["a"]}"#
        let draft = try JSONDecoder().decode(BugDraft.self, from: Data(json.utf8))
        #expect(draft.plain == nil)
        #expect(draft.details == "a")
    }
}
