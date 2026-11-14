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
            ("stop the preview", .stopPreview), ("turn off the preview", .stopPreview), ("shut down the preview", .stopPreview),
            ("make the preview full screen", .fullWindowPreview), ("make the preview bigger", .fullWindowPreview),
            ("show it on a phone", .phoneView), ("how does it look on mobile?", .phoneView), ("show the preview at phone size", .phoneView),
            ("show it on an iPad", .tabletView), ("desktop view", .desktopView), ("see the site on a laptop", .desktopView),
            ("let me point at it", .pickMode), ("I want to pick something", .pickMode),
            ("show your info", .botInfo), ("bot info", .botInfo), ("open your details", .botInfo),
            ("pair with darkmux", .pairing), ("connect to darkmux", .pairing),
            ("review my changes", .startReview), ("start a review", .startReview),
            ("undo that", .undoLast), ("undo", .undoLast), ("revert the last change", .undoLast),
            ("stop", .stopRun), ("stop the run", .stopRun),
            ("clear the chat", .clearConversation), ("start the conversation over", .clearConversation),
            ("archive this bot", .archiveBot), ("archive yourself", .archiveBot),
            ("delete this bot", .deleteBot), ("remove this project", .deleteBot),
            ("publish it", .publish), ("how do I put it on the internet", .publish), ("deploy the site", .publish),
            ("save my changes", .save), ("is it saved?", .save), ("how do I save my work?", .save),
        ]
        for (text, action) in cases { #expect(AppAction.match(text) == action, "\(text)") }
    }

    @Test func workThatNamesTheSameThingIsNotAnAction() {
        for text in ["hide the price on the preview", "close the menu in the preview", "reload the data when the preview opens",
                     "hide the header", "refresh the page every minute", "close and reload the preview",
                     "make the preview button bigger", "stop the video in the preview", "make the menu smaller on phones",
                     "show the phone number in the footer", "pick a color for the header", "add an info box", "what is darkmux?",
                     "turn the preview", "review the login code", "undo the header color change", "stop the video autoplaying",
                     "clear the form after submit", "archive the old posts", "delete the about section", "add a chat widget",
                     "add a save button", "save the form to local storage"] {
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

    @Test func undoThatPostsACardAndStartsNothing() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = store.add(name: "Notes", instructions: "")
        await brain.send("undo that", in: .bot(bot.id), store: store)
        // Nothing to undo: it says so, and no card or run.
        let messages = store.conversation(for: .bot(bot.id)).messages ?? []
        #expect(messages.contains { $0.content == String(localized: "There's nothing to undo yet.") })
        #expect(!messages.contains { $0.kind == .actionCard })
        #expect((bot.runs ?? []).isEmpty)
    }

    @Test func clearTheChatWaitsForApprove() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = store.add(name: "Notes", instructions: "")
        await brain.send("clear the chat", in: .bot(bot.id), store: store)
        let card = (store.conversation(for: .bot(bot.id)).messages ?? []).first { $0.kind == .actionCard }
        #expect(card?.action == .app(.clearConversation, runId: nil, detail: AppAction.clearConversation.cardDetail(bot: "Notes", task: nil)))
        #expect(brain.appActionRequested == nil, "nothing happens before Approve")
        if let card { brain.resolve(card, approve: true, store: store) }
        #expect(brain.appActionRequested == AppActionRequest(bot: bot.id, action: .clearConversation))
    }

    @Test func deleteIsAnsweredNeverWork() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = store.add(name: "Notes", instructions: "")
        await brain.send("delete this bot", in: .bot(bot.id), store: store)
        #expect((bot.runs ?? []).isEmpty)
        #expect(store.conversation(for: .bot(bot.id)).messages?.contains { $0.content == AppAction.deleteBot.doingText } == true)
    }

    @Test func typedYesNeverApprovesACard() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = store.add(name: "Notes", instructions: "")
        let run = store.proposeRun(task: "Make the header blue", crew: .coder, on: bot)
        await brain.send("yes", in: .bot(bot.id), store: store)
        #expect(run.phase == .proposed)
        #expect((bot.runs ?? []).count == 1)
    }
}
