import Foundation
import Testing
@testable import MuxBot

/// "start the preview" opens the preview, never a crew run, and a project
/// with no work copy yet still has its Preview button.
@MainActor
struct PreviewRequestTests {
    @Test func asksForThePreviewAreMatched() {
        for text in ["start the preview", "Start the preview.", "show me the preview", "where's the preview?",
                     "open preview", "can you start the preview please", "where is the preview button?", "restart the preview"] {
            #expect(PreviewRequest.matches(text), "\(text)")
        }
    }

    @Test func workThatNamesThePreviewIsNot() {
        for text in ["show the price on the preview", "make the preview button bigger", "fix the header in the preview",
                     "start the page", "preview the new pricing page for phones and tablets with the menu open"] {
            #expect(!PreviewRequest.matches(text), "\(text)")
        }
    }

    @Test func startThePreviewOpensItAndProposesNoRun() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let bot = store.add(name: "Get Tested", instructions: "")
        store.addResource(.repo, "https://github.com/someone/get-tested", to: bot)
        await brain.send("start the preview", in: .bot(bot.id), store: store)
        #expect((bot.runs ?? []).isEmpty, "no crew run")
        #if os(macOS)
        #expect(brain.previewRequested == bot.id)
        #expect(store.conversation(for: .bot(bot.id)).messages?.contains { $0.content == PreviewRequest.openingText } == true)
        #endif
    }

    @Test func aRepoWithNoWorkCopyStillHasThePreviewButton() {
        let store = TestStore.fresh()
        let runs = RunCoordinator()
        let bot = store.add(name: "Get Tested", instructions: "")
        #expect(!runs.canPreview(bot), "nothing to preview")
        store.addResource(.repo, "https://github.com/someone/get-tested", to: bot)
        #if os(macOS)
        #expect(runs.canPreview(bot))
        #endif
    }

    @Test func aWorkCopyThatCantBeMadeSaysSoInThePanel() async {
        let store = TestStore.fresh()
        let runs = RunCoordinator()
        struct Refused: Error {}
        runs.workspaceMaker = { _ in throw Refused() }
        let bot = store.add(name: "Get Tested", instructions: "")
        store.addResource(.repo, "https://github.com/someone/get-tested", to: bot)
        await runs.ensurePreview(for: bot)
        #expect(runs.livePreviews[bot.id]?.status == .unavailable(.noWorkCopy))
    }

    @Test func theEvalRunnerIsOnlyForEvals() {
        #expect(FallbackBrain.checkedCrew(.evalRunner, request: "Start the preview") == .coder)
        #expect(FallbackBrain.checkedCrew(.evalRunner, request: "run the benchmark again") == .evalRunner)
        #expect(FallbackBrain.checkedCrew(.reviewer, request: "look this over") == .reviewer)
    }
}
