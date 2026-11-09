import Foundation
import Testing
@testable import MuxBot

/// A new bot gets a fresh look: a random animal (never the lead bot's
/// octopus), the least used ones first, and colors that don't repeat a bot
/// already there. Templates' look fields no longer set it.
struct FreshLookTests {
    /// A generator that gives the same numbers for the same seed.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func neverTheLeadBotsOctopus() {
        var rng = Seeded(state: 1)
        for _ in 0..<500 { #expect(BotLook.fresh(avoiding: [], using: &rng).animal != .octopus) }
    }

    @Test func theLeastUsedAnimalsComeFirst() {
        let others = BotAnimal.allCases.filter { $0 != .octopus && $0 != .frog }
        let existing = others.map { BotLook(animal: $0, bodyHex: "5b5bd6", eyeHex: "3fdcff") }
        var rng = Seeded(state: 7)
        for _ in 0..<50 { #expect(BotLook.fresh(avoiding: existing, using: &rng).animal == .frog, "the one animal no bot has") }
    }

    @Test func aColorAlreadyPairedWithThatAnimalIsAvoided() {
        // Every fox color but the last is taken; the fox is the only choice.
        let taken = BotLook.bodyColors.dropLast().map { BotLook(animal: .fox, bodyHex: $0, eyeHex: "3fdcff") }
        for seed in 0..<20 as Range<UInt64> {
            var rng = Seeded(state: seed)
            #expect(BotLook.fresh(avoiding: taken, using: &rng, animals: [.fox]).bodyHex == BotLook.bodyColors.last)
        }
    }

    @Test func theSameSeedGivesTheSameLook() {
        var a = Seeded(state: 42), b = Seeded(state: 42)
        #expect(BotLook.fresh(avoiding: [], using: &a) == BotLook.fresh(avoiding: [], using: &b))
        var c = Seeded(state: 43)
        let looks = (0..<20).map { _ in BotLook.fresh(avoiding: [], using: &c) }
        #expect(Set(looks.map(\.animal)).count > 3, "it varies")
    }
}

@Suite(.serialized) @MainActor
struct StartWithALookTests {
    @Test func startingAProjectUsesTheLookYouSaw() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let playbook = try Playbook.parse(PlaybookParserTests.website)
        brain.runs.workspaceMaker = { _ in DarkmuxClient.Workspace(workspace: "w-1", branch: "main", created: true) }
        let seen = BotLook(animal: .panda, bodyHex: "e0732d", eyeHex: "ff7fd0")
        let bot = await StartProject.start(TemplateRegistryTests.entry, playbook: playbook,
                                           answers: .init(name: "Bakery", purpose: "a bakery"), look: seen,
                                           store: store, runs: brain.runs)
        #expect(bot.look == seen, "not the playbook's fox")
    }

    @Test func twoProjectsFromOneTemplateLookDifferent() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let playbook = try Playbook.parse(PlaybookParserTests.website)
        brain.runs.workspaceMaker = { _ in DarkmuxClient.Workspace(workspace: "w-\(UUID().uuidString.prefix(4))", branch: "main", created: true) }
        let a = await StartProject.start(TemplateRegistryTests.entry, playbook: playbook, answers: .init(name: "One", purpose: "x"), store: store, runs: brain.runs)
        let b = await StartProject.start(TemplateRegistryTests.entry, playbook: playbook, answers: .init(name: "Two", purpose: "x"), store: store, runs: brain.runs)
        #expect(a.look.animal != b.look.animal, "the second avoids the first's animal")
    }

    @Test func anExistingProjectGetsAFreshLookToo() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.runs.workspaceMaker = { _ in DarkmuxClient.Workspace(workspace: "x-1", branch: "main", created: true) }
        let seen = BotLook(animal: .otter, bodyHex: "3d9a4a", eyeHex: "ffc23d")
        let (bot, _) = await ExistingProject.start(.github(repo: "kain/site", checkout: nil), name: "Site", purpose: "x",
                                                   projectPlaybook: nil, look: seen, store: store, runs: brain.runs)
        #expect(bot.look == seen)
    }
}
