import Foundation
import Testing
@testable import MuxBot

/// The issue Mux Bot drafts carries the layout measurement, a likely place,
/// and an Expected that describes what you should see, never a guessed fix
/// (hcr#10 said "Adjust the animation timing…" and measured only padding).
struct BugDraftWidthTests {
    @Test func aDraftMeasuresAroundTheReportedWidth() {
        #expect(LayoutMeasure.widths(around: 820) == [820, 768, 1024, 1440])
        #expect(LayoutMeasure.widths(around: 700) == [700, 390, 768, 1440])
        #expect(LayoutMeasure.widths(around: 1440) == [1440, 1024])
    }

    @Test(arguments: [
        "Adjust the animation timing to ensure the text wraps correctly and the animation does not push the content off-screen.",
        "Add a media query for tablets.",
        "Set the hero to flex-direction: column at 820px.",
        "Increase the padding on the container.",
    ])
    func guessedFixesAreNotExpectations(line: String) {
        #expect(!BugReport.isOutcomeOnly(line), "\(line)")
    }

    @Test(arguments: [
        "The code animation stays beside the text without being pushed off the screen.",
        "The heading stays on one line at tablet width.",
    ])
    func outcomesAre(line: String) {
        #expect(BugReport.isOutcomeOnly(line), "\(line)")
    }
}

@Suite(.serialized) @MainActor
struct BugDraftMeasureFlowTests {
    let hero = PickedElement(label: "> Scal", selector: "div#app > div.layout > main > section.hero.container:nth-of-type(1)", tag: "section",
                             url: "/", viewport: 820, left: 0, right: 0, width: 820, height: 300,
                             paddingLeft: "20px", paddingRight: "20px", marginLeft: "0px", marginRight: "0px", x: 0, y: 80)

    private func draft(probe: MockProbe?) async throws -> BugDraft {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        store.addResource(.previewURL, "http://127.0.0.1:5999/", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.layoutProbe = probe
        await brain.send("tablet sizing looks off, the animated code gets pushed to the right", in: .bot(bot.id), store: store, element: hero)
        let card = try #require((store.conversation(for: .bot(bot.id)).messages ?? []).last { $0.kind == .bugCard })
        return try JSONDecoder().decode(BugDraft.self, from: Data(card.content.utf8))
    }

    @Test func theDraftCarriesTheLayoutSwitchItsPlaceAndAnOutcome() async throws {
        let probe = MockProbe([820: heroAt(820), 768: heroAt(768), 1024: heroAt(1024), 1440: heroAt(1440)])
        let d = try await draft(probe: probe)
        #expect(probe.asked.first?.widths == [820, 768, 1024, 1440])
        #expect(d.facts.contains("At 820px section.hero.container.flex is a row (402px and 378px side by side); at 768px it's a column, from @media (max-width: 768px) in inertia/css/app.css."), "\(d.facts)")
        #expect(d.likelyPlace == "inertia/css/app.css, @media (max-width: 768px)")
        #expect(d.expected == "From 769px to 1024px section.hero.container.flex is a column, as at 768px, and 1440px looks the same as now.")
        #expect(d.body.contains("**Likely place**\ninertia/css/app.css, @media (max-width: 768px)"), "\(d.body)")
    }

    @Test func withoutAPreviewTheDraftSaysWhatItCouldMeasure() async throws {
        let d = try await draft(probe: nil)
        #expect(d.likelyPlace == nil)
        #expect(d.expected == nil, "no guessed fix; the placeholder asks you")
    }
}
