import Foundation
import Testing
@testable import MuxBot

/// The registry of things the app does itself: each entry matches only its
/// own words, so asking for the app never becomes crew work, and work that
/// names the same thing never becomes an app action.
@MainActor
struct AppActionTests {
    @Test func eachActionMatchesItsOwnPhrasings() {
        let cases: [(String, AppAction)] = [
            ("start the preview", .openPreview), ("where's the preview?", .openPreview), ("preview", .openPreview),
            ("hide the preview", .hidePreview), ("close the preview please", .hidePreview), ("Hide preview.", .hidePreview),
            ("reload the preview", .reloadPreview), ("refresh the preview", .reloadPreview), ("can you reload the preview", .reloadPreview),
        ]
        for (text, action) in cases { #expect(AppAction.match(text) == action, "\(text)") }
    }

    @Test func workThatNamesTheSameThingIsNotAnAction() {
        for text in ["hide the price on the preview", "close the menu in the preview", "reload the data when the preview opens",
                     "hide the header", "refresh the page every minute", "close and reload the preview"] {
            #expect(AppAction.match(text) == nil, "\(text)")
        }
    }

    @Test func hideThePreviewNeverProposesARun() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = store.add(name: "Get Tested", instructions: "")
        store.addResource(.repo, "https://github.com/someone/get-tested", to: bot)
        await brain.send("hide the preview", in: .bot(bot.id), store: store)
        #expect((bot.runs ?? []).isEmpty, "no crew run")
        #expect(brain.appActionRequested == AppActionRequest(bot: bot.id, action: .hidePreview))
    }

    @Test func anActionThatCantHappenSaysWhyAndProposesNoRun() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = store.add(name: "Notes", instructions: "")
        await brain.send("reload the preview", in: .bot(bot.id), store: store)
        #expect((bot.runs ?? []).isEmpty, "no crew run")
        #expect(brain.appActionRequested == nil)
        #expect(store.conversation(for: .bot(bot.id)).messages?.contains { $0.content == PreviewRequest.cantText(bot.name) } == true)
    }
}
