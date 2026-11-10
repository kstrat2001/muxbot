import CoreGraphics
import Foundation
import Testing
@testable import MuxBot

/// Sweep batch 8: layouts keep your place, and polish.
@Suite(.serialized) @MainActor
struct LayoutSweepTests {
    // 1: iPhone Home's bar shows the thread it sends to.

    @Test func sendingFromHomeOpensMuxBotsThread() {
        let router = AppRouter()
        router.usesSidebar = false
        router.showLeadBeforeSending()
        #expect(router.path == [.lead])
        let id = UUID()
        router.path = [.bot(id)]
        router.showLeadBeforeSending()
        #expect(router.path == [.bot(id)], "a bot's thread stays")
        let sidebar = AppRouter()
        sidebar.usesSidebar = true
        sidebar.showLeadBeforeSending()
        #expect(sidebar.path.isEmpty, "the sidebar layout shows the thread already")
    }

    // 2: a size-class change keeps your place.

    @Test func goingWideKeepsTheThread() {
        let router = AppRouter()
        let id = UUID()
        router.path = [.bot(id)]
        router.layoutChanged(toSidebar: true)
        #expect(router.usesSidebar)
        #expect(router.sidebar == .bot(id))
        #expect(router.path.isEmpty)
        let activity = AppRouter()
        activity.tab = .activity
        activity.layoutChanged(toSidebar: true)
        #expect(activity.sidebar == .activity)
    }

    @Test func goingNarrowKeepsTheThread() {
        let router = AppRouter()
        router.usesSidebar = true
        let id = UUID()
        router.sidebar = .bot(id)
        router.layoutChanged(toSidebar: false)
        #expect(!router.usesSidebar)
        #expect(router.tab == .bots)
        #expect(router.path == [.bot(id)])
        router.layoutChanged(toSidebar: true)
        router.sidebar = .activity
        router.layoutChanged(toSidebar: false)
        #expect(router.tab == .activity)
        #expect(router.path.isEmpty)
    }

    // 5: the guide's Sign in opens Settings on GitHub.

    @Test func signInOpensTheGitHubTab() {
        let defaults = UserDefaults(suiteName: "muxbot-tests-sweep8-\(UUID().uuidString)")!
        SettingsTab.select(.github, in: defaults)
        #expect(defaults.string(forKey: SettingsTab.key) == SettingsTab.github.rawValue)
    }

    // 7: a bot's name is never saved empty.

    @Test func anEmptyNameIsNeverSaved() {
        #expect(BotInfoView.savableName("  ") == nil)
        #expect(BotInfoView.savableName("") == nil)
        #expect(BotInfoView.savableName(" Tides ") == "Tides")
    }

    // 9 + 10: Activity's timer, machine and order.

    @Test func theTimerCountsFromTheStart() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        run.createdAt = Date(timeIntervalSince1970: 1_000)
        #expect(ActivityRow.timerStart(run) == run.createdAt)
        run.startedAt = Date(timeIntervalSince1970: 5_000)
        #expect(ActivityRow.timerStart(run) == Date(timeIntervalSince1970: 5_000), "approved later: from the start, not the proposal")
    }

    @Test func theMachineIsTheRunsNotAlwaysThisMac() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceMachine = "studio"
        let here = store.proposeRun(task: "x", crew: .coder, on: bot)
        RunCoordinator().markStartedHere(here)
        #expect(ActivityRow.machine(for: here) == "studio")
        let elsewhere = store.proposeRun(task: "y", crew: .coder, on: bot)
        #expect(ActivityRow.machine(for: elsewhere) == "Another Mac")
    }

    @Test func hiddenItemsDontSortAsNeedsYou() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        #expect(run.statusRank == 0)
        NeedsYou.dismiss([run])
        #expect(run.statusRank != 0, "hidden here, so not first")
    }

    // 13: long chips wrap inside the width.

    @Test func aChipWiderThanTheRowIsMeasuredAtTheRowsWidth() {
        let natural = CGSize(width: 600, height: 20)
        let fitted = WrappingStack.fitted(natural, width: 300) { width in CGSize(width: width, height: 40) }
        #expect(fitted == CGSize(width: 300, height: 40))
        #expect(WrappingStack.fitted(CGSize(width: 80, height: 20), width: 300) { _ in .zero } == CGSize(width: 80, height: 20))
    }

    // 16: notifications blocked in System Settings.

    @Test func blockedNotificationsSaySo() {
        #expect(NotificationService.cardText(enabled: true, denied: true).contains("System Settings"))
        #expect(NotificationService.cardText(enabled: true, denied: false) == "Notifications are on.")
        #expect(NotificationService.cardText(enabled: false, denied: true) == "Notifications are off.")
    }

    // 17: no empty Mux Bot bubble.

    @Test func aSettingReplyIsNeverEmpty() {
        #expect(LeadGuide.settingReply(explanation: nil, lead: nil) == nil)
        #expect(LeadGuide.settingReply(explanation: "  ", lead: nil) == nil)
        #expect(LeadGuide.settingReply(explanation: "It picks the model.", lead: nil) == "It picks the model.")
    }

    // 18: a setup card's edits survive leaving the thread.

    @Test func aSetupCardKeepsItsEdits() throws {
        let store = TestStore.fresh()
        var setup = PreviewSetup(ProjectSetupDetector.detect(packageJSON: #"{"scripts":{"dev":"vite"}}"#, files: ["package.json"]), folderName: "site")
        let card = store.proposeAction(.setUpPreview(setup), in: .lead)
        setup.command.value = "npm run start"
        store.updateAction(card, to: .setUpPreview(setup))
        guard case let .setUpPreview(saved)? = card.action else { Issue.record("no action"); return }
        #expect(saved.command.value == "npm run start")
        #expect(card.actionState == .waiting)
    }
}
