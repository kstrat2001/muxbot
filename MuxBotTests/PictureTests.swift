import Foundation
import Testing
@testable import MuxBot

/// Your own pictures (darkmux #3545): the chosen file goes to darkmux as
/// bytes, the thread shows the result with Undo, and a spot darkmux can't
/// find goes to Coder with the picture already in the project.
@Suite(.serialized) @MainActor
struct PictureTests {
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
                {"status":"done","result":{},"changes":{"files":[{"path":"public/images/logo-1a2b3c4d.png","added":0,"removed":0}],"diff":""},"commit":"abc1234","branch":"mux/site"}
                """.utf8))
        }
        return (store, bot, brain)
    }

    private let image = PickedElement(label: "img", selector: "header > img", tag: "img", url: "/", viewport: 1200,
                                      left: 0, right: 0, width: 100, height: 20, paddingLeft: "0px", paddingRight: "0px",
                                      marginLeft: "0px", marginRight: "0px", x: 0, y: 0, src: "/logo.svg")
    private let bytes = Data([0x89, 0x50, 0x4E, 0x47])

    @Test func aReplacedPictureIsAResultWithUndo() async {
        let (store, bot, brain) = setUp()
        var sent: (String, String, Data, String?)?
        brain.runs.imageAdder = { workspace, name, data, replace in
            sent = (workspace, name, data, replace)
            return DarkmuxClient.ImageResult(matches: 1, path: "public/images/logo-1a2b3c4d.png", url: "/images/logo-1a2b3c4d.png",
                                             workId: "w-7", commit: "abc1234", branch: "mux/site")
        }
        let url = await brain.runs.addImage(named: "Logo.png", data: bytes, replacing: image, bot: bot, store: store)
        #expect(url == "/images/logo-1a2b3c4d.png")
        #expect(sent?.0 == "site-1" && sent?.1 == "Logo.png" && sent?.2 == bytes && sent?.3 == "/logo.svg")
        let run = try! #require(bot.runs?.first)
        #expect(run.phase == .result)
        #expect(brain.runs.workIds(for: run) == ["w-7"], "Undo reverts darkmux's commit")
        #expect(run.summary.contains("Logo.png"))
    }

    @Test func aSpotDarkmuxCantFindAddsThePictureAndAsksCoder() async {
        let (store, bot, brain) = setUp()
        var replaces: [String?] = []
        brain.runs.imageAdder = { _, _, _, replace in
            replaces.append(replace)
            if replace != nil { return DarkmuxClient.ImageResult(matches: 0) }
            return DarkmuxClient.ImageResult(path: "public/images/logo-1a2b3c4d.png", url: "/images/logo-1a2b3c4d.png",
                                             workId: "w-8", commit: "abc1234", branch: "mux/site")
        }
        await brain.runs.addImage(named: "Logo.png", data: bytes, replacing: image, bot: bot, store: store)
        #expect(replaces == ["/logo.svg", nil])
        let runs = bot.runs ?? []
        #expect(runs.contains { $0.phase == .result }, "the picture is in the project, with Undo")
        let card = try! #require(runs.first { $0.phase == .proposed })
        #expect(card.crew == .coder)
        #expect((card.brief ?? "").contains("header > img") && (card.brief ?? "").contains("/images/logo-1a2b3c4d.png"))
    }

    @Test func aPictureNeedsTheProjectOnThisMacAndAtMostTenMB() async {
        let (store, bot, brain) = setUp()
        brain.runs.imageAdder = { _, _, _, _ in Issue.record("nothing is sent"); return DarkmuxClient.ImageResult() }
        await brain.runs.addImage(named: "big.png", data: Data(count: RunCoordinator.maxImageBytes + 1), replacing: nil, bot: bot, store: store)
        bot.workspaceName = nil
        await brain.runs.addImage(named: "a.png", data: bytes, replacing: nil, bot: bot, store: store)
        #expect((bot.runs ?? []).isEmpty)
        let said = (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
        #expect(said.contains(RunCoordinator.imageTooLarge) && said.contains(RunCoordinator.imageNeedsMac))
    }

    @Test func theImageReplyDecodesDarkmuxsShape() throws {
        let added = try JSONDecoder().decode(DarkmuxClient.ImageResult.self, from: Data(#"{"matches":null,"path":"public/images/a-1.png","url":"/images/a-1.png","work_id":"w-1","commit":"abc1234","branch":"mux/x"}"#.utf8))
        #expect(added.workId == "w-1" && added.url == "/images/a-1.png" && added.matches == nil)
    }

    @Test func aPickedImageCarriesItsSourceAttribute() {
        #expect(BugReport.pageScript.contains("el.getAttribute('src')"))
    }
}
