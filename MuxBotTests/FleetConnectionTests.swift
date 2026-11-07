import Foundation
import Testing
@testable import MuxBot

@Suite(.serialized) @MainActor
struct FleetConnectionTests {
    @Test func workdirIsTheBotsFolderUnderDarkmuxWorktreesWithHomeExpanded() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        store.addResource(.folder, "~/de-projects/hcr", to: bot)
        #expect(FleetConnection.workdir(for: bot) == nil)
        store.addResource(.folder, "~/.darkmux/worktrees/hcr-preview", to: bot)
        let dir = FleetConnection.workdir(for: bot)
        #expect(dir == FleetConnection.realHome + "/.darkmux/worktrees/hcr-preview")
        #expect(!(dir ?? "").contains("Library/Containers"))
    }

    @Test func crewRolesMapToDarkmuxBuiltinRoles() {
        #expect(CrewRole.coder.darkmuxRole == "coder")
        #expect(CrewRole.reviewer.darkmuxRole == "code-reviewer")
        #expect(CrewRole.researcher.darkmuxRole == "analyst")
        #expect(CrewRole.evalRunner.darkmuxRole == nil)
    }

    @Test func unpairedApprovalStaysSimulated() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        let brain = BotBrain()
        brain.simulatedRunSeconds = 3600
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        brain.decide(.approve, on: run, store: store)
        #expect(run.phase == .running)
        #expect(run.darkmuxWorkId == nil)
    }
}
