import Foundation
import Testing
@testable import MuxBot

/// "Set up preview" always does something you can see: it shows the setup
/// card (a new one when the last was used or canceled), or says the
/// preview needs your own checkout. It was silent when a card had been
/// offered before, or when the "needs your checkout" note was already there.
@Suite(.serialized) @MainActor
struct SetUpPreviewButtonTests {
    private func bot(_ store: BotStore) -> Bot {
        let bot = store.add(name: "hcr", instructions: "")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        bot.folderName = "hcr"
        return bot
    }

    private func brain(checkout: URL?) -> BotBrain {
        let brain = BotBrain()
        brain.checkoutFolder = { _ in checkout }
        brain.checkoutReader = { _ in (#"{"scripts":{"dev":"node ace serve --hmr"}}"#, ["package-lock.json"]) }
        return brain
    }

    private func cards(_ store: BotStore, _ bot: Bot) -> [ChatMessage] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.kind == .actionCard }
    }

    @Test func aCanceledCardIsOfferedAgain() {
        let store = TestStore.fresh()
        let bot = bot(store)
        let brain = brain(checkout: URL(fileURLWithPath: "/tmp/hcr"))
        brain.offerPreviewSetup(for: bot, store: store)
        let first = try! #require(cards(store, bot).first)
        brain.resolve(first, approve: false, store: store)
        let offer = brain.offerPreviewSetup(for: bot, store: store, again: true)
        let all = cards(store, bot)
        #expect(all.count == 2, "a fresh card, not silence")
        #expect(offer == .card(all.last!.id))
    }

    @Test func aWaitingCardIsShownNotDuplicated() {
        let store = TestStore.fresh()
        let bot = bot(store)
        let brain = brain(checkout: URL(fileURLWithPath: "/tmp/hcr"))
        brain.offerPreviewSetup(for: bot, store: store)
        let waiting = try! #require(cards(store, bot).first)
        #expect(brain.offerPreviewSetup(for: bot, store: store, again: true) == .card(waiting.id))
        #expect(cards(store, bot).count == 1)
    }

    @Test func noCheckoutSaysSoEveryTime() {
        let store = TestStore.fresh()
        let bot = bot(store)
        let brain = brain(checkout: nil)
        brain.offerPreviewSetup(for: bot, store: store)
        #expect(brain.offerPreviewSetup(for: bot, store: store, again: true) == .needsCheckout)
        #expect(cards(store, bot).isEmpty)
    }

    /// Opened by itself (darkmux found no recipe), it's still offered once.
    @Test func theAutomaticOfferStaysOnce() {
        let store = TestStore.fresh()
        let bot = bot(store)
        let brain = brain(checkout: URL(fileURLWithPath: "/tmp/hcr"))
        brain.offerPreviewSetup(for: bot, store: store)
        brain.resolve(try! #require(cards(store, bot).first), approve: false, store: store)
        brain.offerPreviewSetup(for: bot, store: store)
        #expect(cards(store, bot).count == 1)
    }
}
