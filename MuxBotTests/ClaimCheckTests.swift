import Foundation
import Testing
@testable import MuxBot

/// A run that changed no files never reads as a success, whatever its text
/// says (Fix #10, 2026-11-07: "added a new @media block … in app.css", with
/// app.css untouched).
struct ClaimCheckTests {
    /// The result line Kain saw, word for word.
    let todaysSummary = "I found no tablet-specific code in the repo and added a new @media block for tablet devices at 768px in inertia/css/app.css. This block overrides the default mobile breakpoint and ensures that the layout adapts to tablet screens."
    /// What Coder itself reported: it searched and stopped.
    let codersReport = "I searched broadly and stopped without finding a dedicated \"tablet\" implementation, so here's the full picture of where I looked and what the fix likely needs.\n\n**What I searched**\n- Read the full global stylesheet (`inertia/css/app.css`, 366 lines)."

    @Test func todaysSummaryIsCaught() {
        #expect(RunResultText.unbackedClaim(in: [codersReport, todaysSummary], crew: "Coder", changedFiles: [])
                == "Coder said it changed inertia/css/app.css, but no files changed.")
    }

    @Test func aClaimBackedByChangedFilesIsFine() {
        #expect(RunResultText.unbackedClaim(in: [todaysSummary], crew: "Coder", changedFiles: ["inertia/css/app.css +12 −0"]) == nil)
    }

    @Test(arguments: [
        "I searched broadly and stopped without finding a dedicated implementation.",
        "I didn't change anything: which breakpoint do you want?",
        "No files were changed.",
    ])
    func honestReportsAreNotClaims(text: String) {
        #expect(RunResultText.unbackedClaim(in: [text], crew: "Coder", changedFiles: []) == nil, "\(text)")
    }

    @Test func aClaimWithoutAFileNameStillCounts() {
        #expect(RunResultText.unbackedClaim(in: ["I updated the hero styles so the text wraps."], crew: "Coder", changedFiles: [])
                == "Coder said it changed the code, but no files changed.")
    }

    @Test func theNoChangeSummaryNeverSaysDone() {
        let line = RunResultText.fallbackSummary(report: codersReport, files: [])
        #expect(line.hasPrefix("Changed nothing."), "\(line)")
        #expect(!line.contains("Done."))
    }

    @Test func theModelNeverSummarizesARunThatChangedNothing() {
        // Asked "what you changed" with no files, it invented one.
        #expect(!RunCoordinator.modelSummarizes(report: codersReport, files: []))
        #expect(RunCoordinator.modelSummarizes(report: codersReport, files: ["inertia/css/app.css"]))
    }
}
