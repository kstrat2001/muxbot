import Foundation
import Testing
@testable import MuxBot

private let coderReport = """
**Diagnosis:** The pricing page sets `style={{ padding: '4rem 0 2rem' }}` on its `.container`, which overrides the container's side padding with 0, so the Start_a_Project box touches the edges at narrow widths.

**Change:** In `inertia/pages/pricing.tsx`, set the side padding to 20px: `padding: '4rem 20px 2rem'`.

Files changed: inertia/pages/pricing.tsx
"""

struct RunResultTextTests {
    @Test func fallbackSummaryIsPlainFriendlyAndNamesTheFiles() {
        let text = RunResultText.fallbackSummary(report: coderReport, files: ["inertia/pages/pricing.tsx"])
        #expect(text.hasPrefix("Done."))
        #expect(!text.contains("**"))
        #expect(!text.contains("`"))
        #expect(text.contains("pricing.tsx"))
        #expect(text.count < 320)
    }

    @Test func plainTextStripsMarkdown() {
        #expect(RunResultText.plain("**Diagnosis:** the `container` is _wrong_") == "Diagnosis: the container is wrong")
    }

    @Test(arguments: [
        ("Error: dispatch killed by signal 15 (SIGTERM); exit 143", RunEnd.stopped),
        ("cancelled", .stopped),
        ("signal 9/SIGKILL", .stopped),
        ("[darkmux-liveness] ts +8617ms credential-read\nError: model endpoint refused the connection", .failed("model endpoint refused the connection")),
    ])
    func errorsBecomeAPlainOutcome(raw: String, expected: RunEnd) {
        #expect(RunResultText.classify(error: raw, reason: nil) == expected)
    }

    @Test func plumbingLinesNeverReachChat() {
        let raw = """
        [darkmux-liveness] 2026-11-07T05:54:56Z +8617ms credential-read
        darkmux dispatch: runtime image ghcr.io/kstrat2001/darkmux-runtime:5.9.3 (pulling)
        warning: git unavailable in /darkmux-out
        Error: the coder gave up after 40 tool calls
        """
        #expect(RunResultText.withoutPlumbing(raw) == "Error: the coder gave up after 40 tool calls")
    }
}

@Suite(.serialized) @MainActor
struct RunEndingTests {
    @Test func aFailedRunClosesWithOneLineAndNoDecision() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website", modelName: "")
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        #expect(store.apply(.fail(reason: "model endpoint refused the connection", details: "raw log"), to: run))
        #expect(run.phase == .failed)
        #expect(run.details == "raw log")
        #expect(bot.state == .ready)
        #expect(RunPhase.failed.next(on: .keep) == nil)
    }

    @Test func prCardNeverClaimsAPullRequestWasOpened() {
        #expect(!RunResultText.prUnavailable.localizedCaseInsensitiveContains("opened"))
        #expect(RunResultText.prUnavailable.contains("GitHub"))
    }
}
