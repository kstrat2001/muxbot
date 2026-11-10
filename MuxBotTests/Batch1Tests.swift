import Foundation
import SwiftData
import Testing
@testable import MuxBot

/// Approve cards for actions other than dispatch are saved in the thread, so
/// several can wait at once and survive a relaunch.
@Suite(.serialized) @MainActor
struct ActionCardTests {
    @Test func aProposedActionIsACardInItsThread() async {
        let store = TestStore.fresh()
        store.add(name: "humancodereader", instructions: "The website")
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        await brain.send("Update the pricing copy on humancodereader", in: .lead, store: store)
        let cards = (store.conversation(for: .lead).messages ?? []).filter { $0.kind == .actionCard }
        #expect(cards.count == 1)
        #expect(cards.first?.actionState == .waiting)
        guard case .handOff(_, "humancodereader", _)? = cards.first?.action else {
            Issue.record("expected a hand-off card"); return
        }
    }

    @Test func severalCardsWaitAtOnceAndEachIsDecidedOnce() {
        let store = TestStore.fresh()
        let a = store.add(name: "a", instructions: "A")
        let b = store.add(name: "b", instructions: "B")
        let brain = BotBrain()
        let first = store.proposeAction(.handOff(toId: a.id, toName: "a", task: "one"), in: .lead)
        let second = store.proposeAction(.handOff(toId: b.id, toName: "b", task: "two"), in: .lead)
        brain.resolve(second, approve: true, store: store)
        #expect(first.actionState == .waiting)
        #expect(second.actionState == .approved)
        #expect(b.runs?.count == 1)
        // Deciding again does nothing.
        brain.resolve(second, approve: true, store: store)
        #expect(b.runs?.count == 1)
        brain.resolve(first, approve: false, store: store)
        #expect(first.actionState == .canceled)
        #expect(a.runs?.isEmpty ?? true)
    }

    @Test func theActionSurvivesAReload() throws {
        let store = TestStore.fresh()
        let card = store.proposeAction(.createBot(BotDraft(name: "Life coach", instructions: "Keeps me on track")), in: .lead)
        try store.context.save()
        let id = card.id
        let reloaded = try #require(try store.context.fetch(FetchDescriptor<ChatMessage>(predicate: #Predicate { $0.id == id })).first)
        guard case let .createBot(draft)? = reloaded.action else { Issue.record("action lost"); return }
        #expect(draft.name == "Life coach")
    }
}

struct RunStartFailureTests {
    /// darkmux refusing a run is a failure, never a result to Keep.
    @Test func aRefusedSubmitFailsTheRun() {
        struct Refused: LocalizedError { var errorDescription: String? { "role coder is not defined on this machine" } }
        let event = RunCoordinator.startFailure(Refused())
        #expect(RunPhase.running.next(on: event) == .failed)
        guard case let .fail(reason, details) = event else { Issue.record("expected .fail"); return }
        #expect(reason == "Couldn't start on darkmux")
        #expect(details == "role coder is not defined on this machine")
    }
}

struct WorkBriefTests {
    @Test func hintsComeFromTheRepoNotFromAGuess() {
        let plain = RunCoordinator.workBrief("Fix the gutter")
        #expect(!plain.contains("inertia"))
        let recipe = PreviewManifest(command: "npm run dev", conventions: "Page components are in inertia/pages/.")
        let hinted = RunCoordinator.workBrief("Fix the gutter", recipe: recipe)
        #expect(hinted.contains("Page components are in inertia/pages/."))
    }

    @Test func theLikelyFileComesFromTheRecipesPageFilePattern() {
        #expect(IssueBrief.likelyFile(forPage: "/pricing", pattern: nil) == nil)
        #expect(IssueBrief.likelyFile(forPage: "/pricing", pattern: "inertia/pages/{page}.tsx") == "inertia/pages/pricing.tsx")
        #expect(IssueBrief.likelyFile(forPage: "/", pattern: "inertia/pages/{page}.tsx") == "inertia/pages/home.tsx")
    }

    @Test func theRecipeDecodesItsHints() throws {
        let json = #"{"command": "npm run dev", "port": 3333, "conventions": "Pages live in inertia/pages.", "page_file": "inertia/pages/{page}.tsx"}"#
        let m = try JSONDecoder().decode(PreviewManifest.self, from: Data(json.utf8))
        #expect(m.conventions == "Pages live in inertia/pages.")
        #expect(m.pageFile == "inertia/pages/{page}.tsx")
    }
}

@Suite(.serialized) @MainActor
struct TweakMessageTests {
    @Test func aTweakCarriesTheBriefTheChangedFilesAndTheChange() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        let run = store.proposeRun(task: "Fix #8: gutter", crew: .coder, on: bot, brief: "Fix GitHub issue #8 ... Page: /pricing")
        run.changedFiles = ["inertia/pages/pricing.tsx +1 −1"]
        let message = RunCoordinator.tweakMessage(for: run, change: "use 24px instead")
        #expect(message.contains("Fix GitHub issue #8 ... Page: /pricing"))
        #expect(message.contains("inertia/pages/pricing.tsx"))
        #expect(message.contains("use 24px instead"))
    }
}

@MainActor
struct PairingErrorTests {
    @Test func anEndpointThatIsntRunningIsSaidPlainly() {
        let text = FleetConnection.plainError(URLError(.cannotConnectToHost))
        #expect(text == "darkmux isn't answering on this Mac. Start it in Terminal with the command below, then try again.")
        #expect(!text.contains("`"))
    }

    /// Sweep 2 seam #8: plain words, darkmux's own behind Show details.
    @Test func otherErrorsAreSaidPlainly() {
        let text = FleetConnection.plainError(DarkmuxClient.ClientError(message: "pending requests are capped", status: 429))
        #expect(text == "Pairing didn't work: darkmux has too many pairing requests waiting. Try again in a moment.")
    }
}
