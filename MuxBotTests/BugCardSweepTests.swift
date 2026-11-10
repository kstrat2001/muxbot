#if os(macOS)
import AppKit
import SwiftUI
import Testing
import WebKit
@testable import MuxBot

/// Sweep batch 5: a bug card measures and screenshots only its own bot's
/// preview, keeps its own crop, and Fix it now makes one run.
@Suite(.serialized) @MainActor
struct BugCardSweepTests {
    let element = PickedElement(label: "Hero", selector: "main > section.hero", tag: "section", url: "/",
                                viewport: 820, left: 0, right: 0, width: 820, height: 300,
                                paddingLeft: "0px", paddingRight: "0px", marginLeft: "0px", marginRight: "0px", x: 0, y: 80)

    private func bugCards(_ store: BotStore, _ bot: Bot) -> [ChatMessage] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.kind == .bugCard }.sorted { $0.timestamp < $1.timestamp }
    }

    // 1: only this bot's preview.

    @Test func anotherBotsPageIsNeverMeasuredOrShot() async {
        let preview = PreviewController()
        let a = UUID(), b = UUID()
        preview.show(URL(string: "data:text/html,<p>A</p>")!, for: a)
        #expect(await preview.facts(for: ["A"], bot: b) == nil)
        #expect(await preview.snapshotPNG(bot: b) == nil)
        #expect(await preview.facts(for: ["A"], bot: nil) == nil, "no bot, no page")
    }

    @Test func aBugWhileAnotherBotsPreviewIsUpSaysThePreviewIsntOpen() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let inspector = MockInspector(PageFacts(viewport: 820, url: "/", matches: []))
        inspector.botOnScreen = UUID()   // another bot's page
        brain.pageInspector = inspector
        await brain.send("bug: the footer overlaps the cards", in: .bot(bot.id), store: store)
        let said = (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
        #expect(said.contains { $0.contains("the preview isn't open") }, "\(said)")
        // Its own page on screen: measured.
        inspector.botOnScreen = bot.id
        inspector.askedTerms = []
        await brain.send("bug: the footer overlaps the cards", in: .bot(bot.id), store: store)
        let again = (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }.map(\.content)
        #expect(!(again.last { !$0.hasPrefix("{") } ?? "").contains("the preview isn't open"), "\(again)")
    }

    // 2: each bug keeps its own crop.

    @Test func eachBugKeepsTheCropItWasDraftedWith() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.pageInspector = MockInspector(nil)
        await brain.send("bug: no gutter", in: .bot(bot.id), store: store, element: element, crop: Data([1]))
        await brain.send("bug: too tight", in: .bot(bot.id), store: store, element: element, crop: Data([2]))
        let cards = bugCards(store, bot)
        #expect(cards.count == 2)
        #expect(BugCrops.shared[cards[0].id] == Data([1]))
        #expect(BugCrops.shared[cards[1].id] == Data([2]))
    }

    @Test func removingAChipNeverChangesABugsCrop() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.pageInspector = MockInspector(nil)
        await brain.send("bug: no gutter", in: .bot(bot.id), store: store, element: element, crop: Data([1]))
        let preview = PreviewController()
        preview.picked = element
        preview.pickedCrop = Data([9])
        preview.clearPick()   // the chip's ×
        #expect(BugCrops.shared[bugCards(store, bot)[0].id] == Data([1]))
    }

    // 3: Fix it now makes one run.

    @Test func fixItNowTwiceMakesOneRun() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let draft = BugDraft(title: "Footer overlaps", described: "x", page: "/", viewport: 820, facts: [], repo: nil)
        let card = store.append(.assistant, "{}", kind: .bugCard, to: store.conversation(for: .bot(bot.id)))
        let first = store.fixBug(card, draft: draft, bot: bot)
        let second = store.fixBug(card, draft: draft, bot: bot)
        #expect(first.isNew && !second.isNew)
        #expect(first.run.id == second.run.id)
        #expect(bot.runs?.count == 1)
        #expect(card.runId == first.run.id, "the card shows Sent to Coder")
    }
}
#endif
