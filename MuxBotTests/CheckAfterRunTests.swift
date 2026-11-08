import Foundation
import Testing
@testable import MuxBot

/// After a run that changed files, the app measures again and says whether
/// the done-when holds, and what failed when it doesn't. No model judges it.
struct LayoutCheckTests {
    let before = [heroAt(820), heroAt(768), heroAt(1440)]

    private var spec: LayoutCheck.Spec? {
        LayoutCheck.spec(from: LayoutMeasure.summarize(before, focus: 820), before: before, focus: 820,
                         page: URL(string: "http://127.0.0.1:5999/")!)
    }

    /// The page after a fix: the hero a column up to 1024px.
    func fixed(_ w: Int) -> LayoutFacts {
        var f = heroAt(w <= 1024 ? 768 : w)
        f.viewport = w; f.scrollWidth = w; f.clientWidth = w
        return f
    }

    @Test func theSpecCoversTheRangeTheWidthBelowAndDesktop() throws {
        let s = try #require(spec)
        #expect(s.selector == "section.hero.container.flex")
        #expect(s.wanted == "a column")
        #expect(s.rangeWidths == [820, 1024])
        #expect(s.unchanged == [768: "a column", 1440: "a row (402px and 378px side by side)"])
        #expect(s.widths == [820, 1024, 768, 1440])
    }

    @Test func aFixThatHoldsIsMet() throws {
        let r = LayoutCheck.evaluate(try #require(spec), after: [fixed(820), fixed(1024), fixed(768), heroAt(1440)])
        #expect(r.met, "\(r.failures)")
        #expect(r.failures.isEmpty)
    }

    @Test func aWidthInTheRangeStillWrongIsNamed() throws {
        let r = LayoutCheck.evaluate(try #require(spec), after: [fixed(820), heroAt(1024), fixed(768), heroAt(1440)])
        #expect(!r.met)
        #expect(r.failures == ["At 1024px section.hero.container.flex is a row, not a column."])
    }

    @Test func desktopChangingIsAFailure() throws {
        var desktop = fixed(1440)
        desktop.sections[0].flexDirection = "column"
        let r = LayoutCheck.evaluate(try #require(spec), after: [fixed(820), fixed(1024), fixed(768), desktop])
        #expect(r.failures == ["At 1440px section.hero.container.flex changed from a row to a column."], "\(r.failures)")
    }

    @Test func somethingPushedOffScreenInTheRangeIsAFailure() throws {
        let r = LayoutCheck.evaluate(try #require(spec), after: [overflowingAt820(), fixed(1024), fixed(768), heroAt(1440)])
        #expect(r.failures.contains("At 820px the page is 380px wider than the screen."), "\(r.failures)")
    }

    @Test func noSwitchNoOverflowNoSpec() {
        #expect(LayoutCheck.spec(from: LayoutMeasure.summarize([fitsAt(820), fitsAt(1440)], focus: 820),
                                 before: [fitsAt(820), fitsAt(1440)], focus: 820, page: URL(string: "http://x/")!) == nil)
    }

    @Test func anOverflowSpecChecksTheFocusWidth() throws {
        let before = [overflowingAt820(), fitsAt(1440)]
        let s = try #require(LayoutCheck.spec(from: LayoutMeasure.summarize(before, focus: 820), before: before, focus: 820,
                                              page: URL(string: "http://x/")!))
        #expect(LayoutCheck.evaluate(s, after: [fitsAt(820), fitsAt(1440)]).met)
        #expect(!LayoutCheck.evaluate(s, after: [overflowingAt820(), fitsAt(1440)]).met)
    }

    @Test func theRerunMessageCarriesTheNewNumbers() {
        let text = LayoutCheck.rerunChange(LayoutCheck.Result(met: false, failures: ["At 1024px section.hero.container.flex is a row, not a column."]))
        #expect(text == "Not done yet. Measured in the preview after your change: At 1024px section.hero.container.flex is a row, not a column. Fix that, keeping everything else as it is now.")
    }
}

@Suite(.serialized) @MainActor
struct CheckAfterRunFlowTests {
    @Test func aMeasuredDispatchIsCheckedAfterItsRun() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        store.addResource(.previewURL, "http://127.0.0.1:5999/", to: bot)
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.github = MockGitHub(issues: [issueTen])
        let probe = MockProbe([820: heroAt(820), 768: heroAt(768), 1440: heroAt(1440)])
        brain.layoutProbe = probe
        await brain.send("fix #10", in: .bot(bot.id), store: store)
        let run = try #require(bot.runs?.first)
        #expect(brain.runs.checkSpecs[run.id] != nil, "the plan leaves a check for the run")
        // The run changed app.css; the preview now shows the fix.
        run.changedFiles = ["inertia/css/app.css +2 −2"]
        let after = LayoutCheckTests()
        probe.facts = [820: after.fixed(820), 1024: after.fixed(1024), 768: after.fixed(768), 1440: heroAt(1440)]
        await brain.runs.check(run)
        #expect(brain.runs.runChecks[run.id]?.met == true, "\(String(describing: brain.runs.runChecks[run.id]))")
        #expect(probe.asked.last?.widths == [820, 1024, 768, 1440])
    }

    @Test func aRunThatChangedNothingIsNotChecked() async throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        let brain = BotBrain()
        let probe = MockProbe([820: heroAt(820)])
        brain.layoutProbe = probe
        brain.runs.checkSpecs[run.id] = LayoutCheck.Spec(page: URL(string: "http://x/")!, overflowWidths: [820])
        await brain.runs.check(run)
        #expect(brain.runs.runChecks[run.id] == nil, "nothing changed, nothing to check")
        #expect(probe.asked.isEmpty)
    }
}
