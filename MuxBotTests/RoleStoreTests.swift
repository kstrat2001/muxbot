import Foundation
import SwiftData
import Testing
@testable import MuxBot

/// One in-memory container for every DB suite; suites run serialized so
/// they never share live state.
@MainActor
enum TestStore {
    static let container: ModelContainer = try! SharedModelContainer.inMemory()

    static func fresh() -> RoleStore {
        let context = ModelContext(container)
        try? context.delete(model: RoleTask.self)
        try? context.delete(model: MuxRole.self)
        try? context.delete(model: ChatMessage.self)
        try? context.delete(model: ChatConversation.self)
        try? context.save()
        return RoleStore(context: context)
    }
}

@Suite(.serialized) @MainActor
struct RoleStoreTests {
    @Test func seedsTheFourStarterRolesOnce() {
        let store = TestStore.fresh()
        store.seedIfEmpty()
        store.seedIfEmpty()
        let roles = store.allRoles()
        #expect(roles.map(\.name) == ["Coder", "Reviewer", "Eval runner", "Researcher"])
        #expect(roles.map(\.systemImage) == ["hammer", "magnifyingglass", "gauge", "lightbulb"])
        #expect(roles.allSatisfy { $0.state == .ready })
    }

    @Test func addSavesTrimmedFields() {
        let store = TestStore.fresh()
        store.add(name: "  Release helper ", instructions: " Tags releases ", modelName: " qwen ")
        let role = try! #require(store.allRoles().first)
        #expect(role.name == "Release helper")
        #expect(role.instructions == "Tags releases")
        #expect(role.modelName == "qwen")
        #expect(role.state == .ready)
        #expect(role.avatarImageData == nil)
    }

    @Test func handOffRecordsTaskSetsWorkingAndPostsInTargetThread() {
        let store = TestStore.fresh()
        let role = store.add(name: "Coder", instructions: "Writes code", modelName: "")
        store.handOff(task: "Fix the login bug", from: LeadBot.name, to: role)

        let reloaded = try! #require(store.role(id: role.id))
        #expect(reloaded.state == .working)
        #expect(reloaded.currentTask?.title == "Fix the login bug")
        let thread = store.conversation(for: .bot(role.id))
        #expect((thread.messages ?? []).contains { $0.content == "From \(LeadBot.name): Fix the login bug" })
    }

    @Test func leadAndBotThreadsAreSeparate() {
        let store = TestStore.fresh()
        let role = store.add(name: "Coder", instructions: "Writes code", modelName: "")
        let lead = store.conversation(for: .lead)
        #expect(lead.id == store.conversation(for: .lead).id)
        #expect(lead.id != store.conversation(for: .bot(role.id)).id)
    }

    @Test func approvingAHandOffNotesItInTheSourceThread() {
        let store = TestStore.fresh()
        let role = store.add(name: "Reviewer", instructions: "Reviews", modelName: "")
        let brain = BotBrain()
        brain.pending = .init(context: .lead, action: .handOff(toId: role.id, toName: "Reviewer", task: "Check PR 12"))
        brain.approve(in: store)
        #expect(brain.pending == nil)
        #expect(store.role(id: role.id)?.state == .working)
        #expect((store.conversation(for: .lead).messages ?? []).contains { $0.content == "Handed to Reviewer: Check PR 12" })
    }

    @Test func approvingANewBotSavesIt() {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.pending = .init(context: .lead, action: .createBot(BotDraft(name: "Writer", instructions: "Drafts posts")))
        brain.approve(in: store)
        #expect(store.allRoles().map(\.name) == ["Writer"])
    }

    @Test func cancelLeavesTheStoreAlone() {
        let store = TestStore.fresh()
        let role = store.add(name: "Coder", instructions: "Writes code", modelName: "")
        let brain = BotBrain()
        brain.pending = .init(context: .lead, action: .handOff(toId: role.id, toName: "Coder", task: "x"))
        brain.cancel()
        #expect(brain.pending == nil)
        #expect(store.role(id: role.id)?.state == .ready)
        #expect(role.tasks?.isEmpty ?? true)
    }
}
