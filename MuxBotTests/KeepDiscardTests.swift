import Foundation
import Testing
@testable import MuxBot

struct KeepDiscardTextTests {
    @Test func keepSaysWhatWasCommittedWhere() {
        #expect(RunResultText.kept(files: ["inertia/pages/pricing.tsx"], branch: "mux/humancodereader-3cfe8f", commit: "abc1234")
                == "Committed pricing.tsx to mux/humancodereader-3cfe8f (abc1234).")
        #expect(RunResultText.kept(files: ["a.txt", "b/c.txt", "d.txt"], branch: "mux/x", commit: "1234567")
                == "Committed 3 files to mux/x (1234567).")
    }

    @Test func discardSaysWhatWasPutBack() {
        #expect(RunResultText.discarded(restored: ["README.md"], removed: ["made-by-run.txt"])
                == "Put back README.md. Removed made-by-run.txt.")
        #expect(RunResultText.discarded(restored: ["a", "b"], removed: [])
                == "Put back 2 files.")
        #expect(RunResultText.discarded(restored: [], removed: []) == "Nothing had changed.")
    }

    @Test func thePullRequestCardNamesTheBranch() {
        let text = RunResultText.prUnavailable(branch: "mux/x")
        #expect(text.contains("mux/x"))
        #expect(text.contains("push"))
        #expect(!RunResultText.prUnavailable(branch: nil).contains("mux/"))
    }

    @Test func keepAndDiscardRepliesDecode() throws {
        let kept = try JSONDecoder().decode(DarkmuxClient.KeepResult.self,
            from: Data(#"{"commit":"abc1234","branch":"mux/x","files":["README.md"]}"#.utf8))
        #expect(kept == .init(commit: "abc1234", branch: "mux/x", files: ["README.md"]))
        let discarded = try JSONDecoder().decode(DarkmuxClient.DiscardResult.self,
            from: Data(#"{"restored":["README.md"],"removed":["x.txt"]}"#.utf8))
        #expect(discarded == .init(restored: ["README.md"], removed: ["x.txt"]))
    }
}

@Suite(.serialized) @MainActor
struct KeepCardTests {
    @Test func aKeptRunsCardSaysItWasCommitted() {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site", modelName: "")
        let run = store.proposeRun(task: "Fix", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        store.apply(.finish(summary: "done"), to: run)
        run.keptBranch = "mux/x"
        run.keptCommit = "abc1234"
        store.apply(.keep, to: run)
        let card = (store.conversation(for: .bot(bot.id)).messages ?? []).last { $0.kind == .prCard }
        #expect(card?.content == "Committed to mux/x (abc1234). Open a pull request for it?")
    }
}
