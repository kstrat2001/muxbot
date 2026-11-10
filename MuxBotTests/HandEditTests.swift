import Foundation
import Testing
@testable import MuxBot

/// Edit on a selection in the preview (darkmux #3533): Save changes the
/// file through darkmux and the thread shows the result with Undo; text
/// darkmux can't place goes to Coder as a dispatch card.
@Suite(.serialized) @MainActor
struct HandEditTests {
    private func setUp() -> (BotStore, Bot, BotBrain) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let brain = BotBrain()
        brain.useOnDeviceModel = false
        brain.runs.profileSource = { [] }
        brain.runs.deviceRuns = true
        brain.runs.workStatusFetcher = { _ in
            try JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data("""
                {"status":"done","result":{},"changes":{"files":[{"path":"src/App.tsx","added":1,"removed":1}],"diff":"-Hello\\n+Hi"},"commit":"abc1234","branch":"mux/site"}
                """.utf8))
        }
        return (store, bot, brain)
    }

    private let picked = PickedElement(label: "Hello", selector: "main > h1", tag: "h1", url: "/", viewport: 1200,
                                       left: 0, right: 0, width: 100, height: 20, paddingLeft: "0px", paddingRight: "0px",
                                       marginLeft: "0px", marginRight: "0px", x: 0, y: 0, selectedText: "Hello there", edit: true)

    @Test func aPlacedEditIsAResultWithUndo() async {
        let (store, bot, brain) = setUp()
        var sent: (String, String, String)?
        brain.runs.handEditor = { workspace, old, new in
            sent = (workspace, old, new)
            return DarkmuxClient.EditResult(matches: 1, workId: "w-9", file: "src/App.tsx", commit: "abc1234", branch: "mux/site")
        }
        await brain.runs.handEdit(picked, to: "Hi there", bot: bot, store: store)
        #expect(sent?.0 == "site-1" && sent?.1 == "Hello there" && sent?.2 == "Hi there")
        let run = try! #require(bot.runs?.first)
        #expect(run.phase == .result)
        #expect(run.keptCommit == "abc1234")
        #expect(run.changedFiles == ["src/App.tsx +1 −1"])
        #expect(brain.runs.workIds(for: run) == ["w-9"], "Undo reverts darkmux's commit")
        #expect(run.startedHere)
        #expect(run.summary.contains("Hi there"))
    }

    @Test func textDarkmuxCantPlaceGoesToCoderAsADispatchCard() async {
        let (store, bot, brain) = setUp()
        for matches in [0, 2] {
            brain.runs.handEditor = { _, _, _ in DarkmuxClient.EditResult(matches: matches) }
            await brain.runs.handEdit(picked, to: "Hi there", bot: bot, store: store)
        }
        let runs = bot.runs ?? []
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.phase == .proposed && $0.crew == .coder })
        #expect(runs.allSatisfy { ($0.brief ?? "").contains("main > h1") && ($0.brief ?? "").contains("Hello there") && ($0.brief ?? "").contains("Hi there") })
    }

    @Test func noProjectOnThisMacSaysEditsAreMadeFromTheMac() async {
        let (store, bot, brain) = setUp()
        bot.workspaceName = nil
        brain.runs.handEditor = { _, _, _ in Issue.record("nothing is sent"); return DarkmuxClient.EditResult(matches: 0) }
        await brain.runs.handEdit(picked, to: "Hi", bot: bot, store: store)
        #expect((bot.runs ?? []).isEmpty)
        let said = (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
        #expect(said.contains(RunCoordinator.handEditNeedsMac))
    }

    @Test func theEditReplyDecodesDarkmuxsShape() throws {
        let edited = try JSONDecoder().decode(DarkmuxClient.EditResult.self, from: Data(#"{"matches":1,"work_id":"w-1","file":"a.html","commit":"abc1234","branch":"mux/x"}"#.utf8))
        #expect(edited.workId == "w-1")
        let missed = try JSONDecoder().decode(DarkmuxClient.EditResult.self, from: Data(#"{"matches":2,"work_id":null,"file":null,"commit":null,"branch":null}"#.utf8))
        #expect(missed.matches == 2 && missed.workId == nil)
    }

    @Test func theMacPageOffersEdit() {
        #expect(BugReport.pageScript.contains("window.__muxCanEdit"))
        #expect(BugReport.canEditScript.contains("__muxCanEdit = true"))
    }
}
