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

    @Test func assignRecordsTaskAndSetsWorking() {
        let store = TestStore.fresh()
        let role = store.add(name: "Coder", instructions: "Writes code", modelName: "")
        store.assign(task: "Fix the login bug", why: "It writes code", to: role)

        let reloaded = try! #require(store.role(id: role.id))
        #expect(reloaded.state == .working)
        #expect(reloaded.currentTask?.title == "Fix the login bug")
        let convo = ChatService.conversation(for: role.id, title: role.name, context: store.context)
        #expect((convo.messages ?? []).contains { $0.content.contains("Fix the login bug") })
    }

    @Test func approvingANewRolePlanSavesIt() {
        let store = TestStore.fresh()
        let planner = RadioPlanner()
        planner.plan = .newRole(RoleDraft(name: "Writer", instructions: "Drafts posts"), why: "Asked for it")
        planner.approve(in: store)
        #expect(store.allRoles().map(\.name) == ["Writer"])
        #expect(planner.plan == nil)
    }

    @Test func cancelLeavesTheStoreAlone() {
        let store = TestStore.fresh()
        let role = store.add(name: "Coder", instructions: "Writes code", modelName: "")
        let planner = RadioPlanner()
        planner.plan = .assign(roleId: role.id, roleName: "Coder", task: "x", why: "y")
        planner.cancel()
        #expect(planner.plan == nil)
        #expect(store.role(id: role.id)?.state == .ready)
        #expect(role.tasks?.isEmpty ?? true)
    }
}
