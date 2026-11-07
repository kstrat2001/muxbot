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

    @Test func unpairedApprovalDoesNotStartAnythingAndSaysWhy() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        let brain = BotBrain()
        let run = store.proposeRun(task: "Fix #8", crew: .coder, on: bot)
        #expect(brain.whyRunCannotStart(run) == "this app isn't paired with darkmux")
        brain.decide(.approve, on: run, store: store)
        #expect(run.phase == .proposed)
        #expect(run.darkmuxWorkId == nil)
        #expect((store.conversation(for: .bot(bot.id)).messages ?? []).contains { $0.content == "Can't run this yet: this app isn't paired with darkmux." })
    }

    @Test func cancelStillWorksWhenUnpaired() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        BotBrain().decide(.cancel, on: run, store: store)
        #expect(run.phase == .canceled)
    }
}

@MainActor
struct SidebarRoutingTests {
    @Test func inSidebarModeOpeningABotSelectsItWithoutPushing() {
        let router = AppRouter()
        router.usesSidebar = true
        let id = UUID()
        router.navigate(to: .bot(id))
        #expect(router.sidebar == .bot(id))
        #expect(router.path.isEmpty)
        #expect(router.context == .bot(id))
        router.sidebar = .work
        #expect(router.context == .lead)
    }

    @Test func inTabModeOpeningABotPushesIt() {
        let router = AppRouter()
        let id = UUID()
        router.navigate(to: .bot(id))
        #expect(router.path == [.bot(id)])
        #expect(router.context == .bot(id))
    }

    @Test func unreadIsABotMessageNewerThanTheLastLook() {
        let store = TestStore.fresh()
        let thread = store.conversation(for: .lead)
        #expect(!thread.hasUnread)
        store.append(.assistant, "hi", to: thread)
        #expect(thread.hasUnread)
        thread.lastReadAt = .now
        #expect(!thread.hasUnread)
        store.append(.user, "hello", to: thread)
        #expect(!thread.hasUnread)
    }
}
