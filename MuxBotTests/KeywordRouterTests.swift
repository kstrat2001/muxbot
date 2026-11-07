import Foundation
import Testing
@testable import MuxBot

struct KeywordRouterTests {
    let roles: [RoleSummary] = RoleStore.defaults.map {
        RoleSummary(id: UUID(), name: $0.name, instructions: $0.instructions, state: .ready)
    }

    private func assignee(_ request: String) -> String? {
        if case let .assign(_, name, _, _) = KeywordRouter.plan(for: request, roles: roles) { return name }
        return nil
    }

    @Test(arguments: [
        ("Fix the crash in the settings screen bug", "Coder"),
        ("Please review my pull request", "Reviewer"),
        ("Benchmark qwen against gemma", "Eval runner"),
        ("Research long context papers", "Researcher"),
    ])
    func routesByKeyword(request: String, expected: String) {
        #expect(assignee(request) == expected)
    }

    @Test func noMatchFallsBackToAReadyRoleAndSaysSo() {
        var roster = roles
        roster[0].state = .working
        let plan = KeywordRouter.plan(for: "zzz qqq", roles: roster)
        guard case let .assign(_, name, task, why) = plan else { Issue.record("expected assign"); return }
        #expect(name == "Reviewer")
        #expect(task == "zzz qqq")
        #expect(why.contains("No keyword matched"))
    }

    @Test func newRoleRequestDraftsARole() {
        let plan = KeywordRouter.plan(for: "Make a new role called Release helper that tags releases", roles: roles)
        guard case let .newRole(draft, _) = plan else { Issue.record("expected newRole"); return }
        #expect(draft.name == "Release helper")
        #expect(draft.instructions == "tags releases")
    }

    @Test func emptyRosterDraftsARole() {
        guard case .newRole = KeywordRouter.plan(for: "fix a bug", roles: []) else {
            Issue.record("expected newRole"); return
        }
    }
}
