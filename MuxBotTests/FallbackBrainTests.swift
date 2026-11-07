import Foundation
import Testing
@testable import MuxBot

struct FallbackBrainTests {
    let bots: [BotSummary] = RoleStore.defaults.map {
        BotSummary(id: UUID(), name: $0.name, instructions: $0.instructions, state: .ready)
    }
    let fleet = FleetSnapshot.sample

    private func turn(_ text: String, speaker: BotSummary? = nil) -> BotTurn {
        FallbackBrain.turn(for: text, speaker: speaker, bots: bots, fleet: fleet)
    }

    private func handOffTarget(_ turn: BotTurn) -> String? {
        if case let .handOff(_, name, _) = turn.action { return name }
        return nil
    }

    @Test(arguments: [
        ("Fix the crash bugs in the settings screen", "Coder"),
        ("Please review my pull request", "Reviewer"),
        ("Benchmark qwen against gemma", "Eval runner"),
        ("Research long context papers", "Researcher"),
    ])
    func leadBotHandsOffByKeyword(request: String, expected: String) {
        #expect(handOffTarget(turn(request)) == expected)
    }

    @Test func leadBotAsksWhenNothingMatches() {
        let result = turn("zzz qqq")
        #expect(result.action == nil)
        #expect(result.reply.contains("Which bot"))
    }

    @Test func botHandsOffWhenAnotherBotIsNamed() {
        #expect(handOffTarget(turn("ask the reviewer to check it", speaker: bots[0])) == "Reviewer")
    }

    @Test func botKeepsWorkThatDoesNotNameAnotherBot() {
        let result = turn("research long context papers", speaker: bots[0])
        #expect(result.action == nil)
    }

    @Test func botNamingItselfIsNotAHandOff() {
        #expect(turn("coder, refactor the parser", speaker: bots[0]).action == nil)
    }

    @Test func fleetQuestionNamesTheRoomiestOnlineMachine() {
        let result = turn("which machine is free for a big model?")
        #expect(result.action == nil)
        #expect(result.reply.contains("MacBook Pro"))
        #expect(result.reply.contains("74 GB free"))
        #expect(result.reply.contains("Sample data"))
    }

    @Test func roomiestMachineSkipsOfflineMachines() {
        // Mac Studio has the most memory but is offline.
        #expect(fleet.roomiestMachine?.name == "MacBook Pro")
    }

    @Test func newBotRequestDraftsABot() {
        guard case let .createBot(draft) = turn("add a bot called Writer that drafts posts").action else {
            Issue.record("expected createBot"); return
        }
        #expect(draft.name == "Writer")
        #expect(draft.instructions == "drafts posts")
    }
}
