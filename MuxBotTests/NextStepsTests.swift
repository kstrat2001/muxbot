import Foundation
import Testing
@testable import MuxBot

@MainActor
struct NextStepsTests {
    @Test func helpPhrasesMatchAndWorkDoesNot() {
        for text in ["help", "Help me", "I'm stuck", "what can I do?", "what now?", "where do I start?", "?", "I don’t know what to do", "what's next?", "what can you change?", "any suggestions?"] {
            #expect(NextSteps.matches(text), "\(text)")
        }
        for text in ["help me make the header blue", "add a help page", "what can I do about the slow page?", "stuck header on scroll"] {
            #expect(!NextSteps.matches(text), "\(text)")
        }
    }

    @Test func helpMePostsNextStepsAndProposesNoRun() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = store.add(name: "Notes", instructions: "")
        await brain.send("help me", in: .bot(bot.id), store: store)
        #expect((bot.runs ?? []).isEmpty, "no crew run")
        let card = (store.conversation(for: .bot(bot.id)).messages ?? []).first { $0.kind == .guideCard }?.guideCard
        guard case let .nextSteps(status, _)? = card else { Issue.record("no next-steps card"); return }
        #expect(status == String(localized: "Nothing's been changed yet. Pick one of these to start."))
    }

    @Test func aWaitingCardComesFirst() {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = store.add(name: "Notes", instructions: "")
        _ = store.proposeRun(task: "Make the header blue", crew: .coder, on: bot)
        let next = NextSteps.read(bot, runs: brain.runs, store: store)
        #expect(next.status.contains("Approve"))
        #expect(next.steps.isEmpty)
    }

    @Test func everyStepGoesTheWayTypingItWould() {
        // A step's message is an app action or a skill's name, never crew work on its own.
        #expect(AppAction.match("show the preview") == .openPreview)
        #expect(AppAction.match("point at something") == .pickMode)
        #expect(AppAction.match("review my changes") == .startReview)
    }

    @Test func examplesComeFromTheSkills() {
        let skills = [BotSkill(name: "Change the look", body: "When: someone wants a new feel. \"Make it dark green\", \"more space\"."),
                      BotSkill(name: "Add a page", body: "When: a new page. \"Add an About page\".")]
        #expect(NextSteps.examples(skills) == String(localized: "You can say things like “Make it dark green” or “Add an About page”."))
        #expect(NextSteps.examples([]) == nil)
    }

    @Test func questionsAboutTheAppAreToldFromProjectWork() {
        for text in ["how do I undo a change?", "can you see my site?", "what does approve do?", "how does the preview work?"] {
            #expect(LeadGuide.isAboutTheApp(text), "\(text)")
        }
        for text in ["how do I make the header blue?", "make the preview button bigger", "can you review the login code?", "what pages are there?"] {
            #expect(!LeadGuide.isAboutTheApp(text), "\(text)")
        }
    }

    @Test func aHowToInABotsThreadIsAnsweredFromTheHelp() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let bot = store.add(name: "Notes", instructions: "")
        await brain.send("how do I undo a change?", in: .bot(bot.id), store: store)
        #expect((bot.runs ?? []).isEmpty)
        let card = (store.conversation(for: .bot(bot.id)).messages ?? []).first { $0.kind == .guideCard }?.guideCard
        guard case let .answer(_, articles, _)? = card else { Issue.record("no help answer"); return }
        #expect(!articles.isEmpty)
    }
}
