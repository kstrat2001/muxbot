import Foundation
import SwiftData
import Testing
@testable import MuxBot

/// One in-memory container for every DB suite; suites run serialized so
/// they never share live state.
@MainActor
enum TestStore {
    static let container: ModelContainer = try! SharedModelContainer.inMemory()

    static func fresh() -> BotStore {
        let context = ModelContext(container)
        try? context.delete(model: BotTask.self)
        try? context.delete(model: BotResource.self)
        try? context.delete(model: BotRun.self)
        try? context.delete(model: Bot.self)
        try? context.delete(model: ChatMessage.self)
        try? context.delete(model: ChatConversation.self)
        try? context.save()
        return BotStore(context: context)
    }
}

@Suite(.serialized) @MainActor
struct BotStoreTests {
    @Test func seedsProjectAndThemeBotsOnce() {
        let store = TestStore.fresh()
        store.seedIfEmpty()
        store.seedIfEmpty()
        let bots = store.allBots()
        #expect(bots.map(\.name) == ["humancodereader", "darkmux", "Personal brand", "Daily update"])
        #expect(bots.allSatisfy { $0.state == .ready })
        // A test preview URL may follow, from this machine's Local.xcconfig.
        // A test preview URL and work folder may follow, from this machine's Local.xcconfig.
        let hcr = bots[0].sortedResources.filter { $0.kind != .previewURL && $0.value != BotStore.testWorkdir }
        #expect(hcr.map(\.kind) == [.repo])
        #expect(bots[0].sortedResources.first?.kind == .repo)
        #expect(!bots[0].sortedResources.contains { $0.value == "~/de-projects/hcr" })
        #expect(hcr.first?.value == "https://github.com/kstrat2001/hcr")
    }

    @Test func approvingAddResourceSavesItOnTheThreadsBot() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let card = store.proposeAction(.addResource(kind: .repo, value: "https://github.com/kstrat2001/hcr"), in: .bot(bot.id))
        brain.resolve(card, approve: true, store: store)
        #expect(store.bot(id: bot.id)?.sortedResources.map(\.value) == ["https://github.com/kstrat2001/hcr"])
        #expect((store.conversation(for: .bot(bot.id)).messages ?? []).contains { $0.content.hasPrefix("Added repo:") })
    }

    @Test func dispatchFromTheLeadThreadIsIgnored() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let card = store.proposeAction(.dispatch(crew: .coder, task: "x"), in: .lead)
        brain.resolve(card, approve: true, store: store)
        #expect(card.actionState != .waiting)
        #expect(store.bot(id: bot.id)?.tasks?.isEmpty ?? true)
    }

    @Test func addSavesTrimmedFields() {
        let store = TestStore.fresh()
        store.add(name: "  Release helper ", instructions: " Tags releases ", modelName: " qwen ")
        let role = try! #require(store.allBots().first)
        #expect(role.name == "Release helper")
        #expect(role.instructions == "Tags releases")
        #expect(role.modelName == "qwen")
        #expect(role.state == .ready)
        #expect(role.avatarImageData == nil)
        #expect(role.sortedResources.isEmpty)
    }

    @Test func handOffRecordsTaskSetsWorkingAndPostsInTargetThread() {
        let store = TestStore.fresh()
        let role = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        store.handOff(task: "Fix the login bug", from: LeadBot.name, to: role)

        let reloaded = try! #require(store.bot(id: role.id))
        #expect(reloaded.state == .working)
        #expect(reloaded.currentTask?.title == "Fix the login bug")
        let thread = store.conversation(for: .bot(role.id))
        #expect((thread.messages ?? []).contains { $0.content == "From \(LeadBot.name): Fix the login bug" })
    }

    @Test func leadAndBotThreadsAreSeparate() {
        let store = TestStore.fresh()
        let role = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        let lead = store.conversation(for: .lead)
        #expect(lead.id == store.conversation(for: .lead).id)
        #expect(lead.id != store.conversation(for: .bot(role.id)).id)
    }

    @Test func approvingAHandOffNotesItInTheSourceThread() {
        let store = TestStore.fresh()
        let role = store.add(name: "darkmux", instructions: "CLI", modelName: "")
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let card = store.proposeAction(.handOff(toId: role.id, toName: "darkmux", task: "Check PR 12"), in: .lead)
        brain.resolve(card, approve: true, store: store)
        #expect(card.actionState != .waiting)
        #expect(store.bot(id: role.id)?.state == .working)
        #expect((store.conversation(for: .lead).messages ?? []).contains { $0.content == "Handed to darkmux: Check PR 12" })
    }

    @Test func approvingANewBotSavesIt() {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let card = store.proposeAction(.createBot(BotDraft(name: "Life coach", instructions: "Keeps me on track")), in: .lead)
        brain.resolve(card, approve: true, store: store)
        #expect(store.allBots().map(\.name) == ["Life coach"])
    }

    @Test func cancelLeavesTheStoreAlone() {
        let store = TestStore.fresh()
        let role = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        let card = store.proposeAction(.handOff(toId: role.id, toName: "humancodereader", task: "x"), in: .lead)
        brain.resolve(card, approve: false, store: store)
        #expect(card.actionState != .waiting)
        #expect(store.bot(id: role.id)?.state == .ready)
        #expect(role.tasks?.isEmpty ?? true)
    }
}
