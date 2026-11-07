import Foundation
import Testing
@testable import MuxBot

struct FallbackBrainTests {
    let bots: [BotSummary] = BotStore.defaults.map {
        BotSummary(id: UUID(), name: $0.name, instructions: $0.instructions, state: .ready,
                   resources: $0.resources.map(\.1))
    }
    let fleet = FleetSnapshot.sample

    private var hcr: BotSummary { bots[0] }

    private func turn(_ text: String, speaker: BotSummary? = nil) -> BotTurn {
        FallbackBrain.turn(for: text, speaker: speaker, bots: bots, fleet: fleet)
    }

    private func handOffTarget(_ turn: BotTurn) -> String? {
        if case let .handOff(_, name, _) = turn.action { return name }
        return nil
    }

    // The lead bot routes by theme and resources, not by role.
    @Test(arguments: [
        ("Update the pricing copy on humancodereader", "humancodereader"),
        ("Draft posts about local models for Substack", "Personal brand"),
        ("Run the context sweep evals on darkmux", "darkmux"),
        ("Make a briefing of what ran overnight", "Daily update"),
    ])
    func leadBotRoutesByTheme(request: String, expected: String) {
        #expect(handOffTarget(turn(request)) == expected)
    }

    @Test func leadBotRoutesByResource() {
        // "kstrat2001/hcr" only appears in humancodereader's repo resource.
        #expect(handOffTarget(turn("fix the footer in github.com/kstrat2001/hcr")) == "humancodereader")
    }

    @Test func leadBotAsksWhenNothingMatches() {
        let result = turn("zzz qqq")
        #expect(result.action == nil)
        #expect(result.reply.contains("Which bot"))
    }

    // A bot dispatches to its darkmux crew.
    @Test(arguments: [
        ("Fix the crash bugs in the footer", CrewRole.coder),
        ("Review the pull request for the pricing page", CrewRole.reviewer),
        ("Benchmark page load times", CrewRole.evalRunner),
        ("Research what competitors charge", CrewRole.researcher),
    ])
    func botDispatchesToCrew(request: String, expected: CrewRole) {
        guard case let .dispatch(crew, task) = turn(request, speaker: hcr).action else {
            Issue.record("expected dispatch"); return
        }
        #expect(crew == expected)
        #expect(task == request)
    }

    @Test func botHandsOffWhenAnotherBotIsNamed() {
        #expect(handOffTarget(turn("ask personal brand to post about this launch", speaker: hcr)) == "Personal brand")
    }

    @Test func botNamingItselfIsNotAHandOff() {
        #expect(handOffTarget(turn("humancodereader needs a new footer", speaker: hcr)) == nil)
    }

    @Test(arguments: [
        ("use https://github.com/kstrat2001/hcr-docs for this", ResourceKind.repo),
        ("the site lives at ~/sites/hcr", ResourceKind.folder),
        ("design notes: https://example.com/notes.", ResourceKind.link),
    ])
    func pastedResourceIsProposedForThisBot(text: String, kind: ResourceKind) {
        guard case let .addResource(k, value) = turn(text, speaker: hcr).action else {
            Issue.record("expected addResource"); return
        }
        #expect(k == kind)
        #expect(!value.hasSuffix("."))
    }

    @Test func fleetQuestionNamesTheRoomiestOnlineMachine() {
        let result = turn("which machine is free for a big model?")
        #expect(result.action == nil)
        #expect(result.reply.contains("MacBook Pro"))
        #expect(result.reply.contains("74 GB free"))
        #expect(result.reply.contains("Sample data"))
    }

    @Test func roomiestMachineSkipsOfflineMachines() {
        #expect(fleet.roomiestMachine?.name == "MacBook Pro")
    }

    @Test func newBotRequestDraftsABot() {
        guard case let .createBot(draft) = turn("add a bot called Life coach that keeps me on track").action else {
            Issue.record("expected createBot"); return
        }
        #expect(draft.name == "Life coach")
        #expect(draft.instructions == "keeps me on track")
    }
}
