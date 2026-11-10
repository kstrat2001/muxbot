import Foundation
import Testing
@testable import MuxBot

/// Sweep batch 9: plain words for every failure; the raw text only behind
/// Show details.
@Suite(.serialized) @MainActor
struct PlainWordsSweepTests {
    // 1: run failures, Undo, Stop, role names, model reasons.

    @Test func anUnknownFailureIsAPlainSentence() {
        let raw = "Traceback (most recent call last):\n  File x\nerror: llama_decode returned -3"
        let why = RunResultText.failure(code: nil, error: raw, reason: nil)
        #expect(!why.contains("llama_decode") && !why.lowercased().contains("error:"), "\(why)")
        #expect(why.contains("details"), "it points at Show details: \(why)")
        #expect(RunResultText.failure(code: "busy", error: raw, reason: nil).hasPrefix("The model was busy"))
        #expect(RunResultText.failure(code: nil, error: "cancelled", reason: "cancelled") == "darkmux stopped it.")
    }

    @Test func undoNeverDoublesItsPrefixOrShowsARawSha() {
        let text = RunResultText.undoRefusal("couldn't undo it: error: could not revert 1a2b3c4d... conflict in src/app.css", runs: [])
        #expect(!text.lowercased().contains("couldn't undo it: couldn't"), "\(text)")
        #expect(!text.contains("1a2b3c4d") && !text.contains("error:"), "\(text)")
    }

    @Test func aLaterRunsUndoIsNamedByItsTask() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let later = store.proposeRun(task: "Make it blue", crew: .coder, on: bot)
        later.keptCommit = "abc1234def5678"
        let text = RunResultText.undoRefusal("commit abc1234 changed the same files later; undo that first", runs: [later])
        #expect(text == "“Make it blue” changed the same files later. Undo that run first.")
        let unknown = RunResultText.undoRefusal("commit fff9999 changed the same files later; undo that first", runs: [later])
        #expect(unknown == "A later run changed the same files. Undo the later run first.")
    }

    @Test func aStopThatRacesTheEndSaysItHadFinished() {
        let raced = DarkmuxClient.ClientError(message: "not running", status: 409)
        #expect(RunCoordinator.stopFailure(raced) == "It had already finished.")
        #expect(!RunCoordinator.stopFailure(URLError(.cannotConnectToHost)).contains("Pairing"))
    }

    @Test func theThreadNamesTheCrewNotDarkmuxsRole() {
        #expect(RunCoordinator.runningLine(crew: .reviewer, profile: nil) == "Running on darkmux: Reviewer.")
        #expect(RunCoordinator.runningLine(crew: .researcher, profile: "flint-rec") == "Running on darkmux: Researcher, on flint-rec.")
    }

    @Test func aModelReasonNamesTheRunsCrew() {
        let listed = [DarkmuxClient.ProfileInfo(name: "rev", endpoint: "e", reachable: true)]
        let choice = ModelChoice.resolve(mode: .auto, order: [], listed: listed, previous: nil, rerunAfterNotMet: false, crew: "Reviewer")
        #expect(choice.reason == "darkmux's default for Reviewer")
    }

    // 2: GitHub and setup failures.

    @Test func githubStatusesArePlain() {
        #expect(!GitHubError(status: 403, signedIn: true).localizedDescription.contains("rate limit"), "signed in, a 403 isn't the anonymous limit")
        #expect(GitHubError(status: 403, signedIn: false).localizedDescription.contains("rate limit"))
        let busy = GitHubError(status: 502, signedIn: true).localizedDescription
        #expect(!busy.contains("502") && busy.contains("busy"), "\(busy)")
        #expect(!GitHubError(status: 418, signedIn: true).localizedDescription.contains("418"))
    }

    @Test func aPushRefusalShowsNoStatusCode() async {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kain/site/git/ref/heads/mux/site", 502, "")
        let gh = GitHubPR(session: GitHubStub.session, token: "t", local: LocalBotState(fileURL: nil))
        let changes = DarkmuxClient.Changes(base: "b", baseBranch: "main", head: "h", branch: "mux/site", files: [])
        do {
            _ = try await gh.push(changes, repo: "kain/site", message: "m", bot: UUID())
            Issue.record("expected a refusal")
        } catch {
            let text = error.localizedDescription
            #expect(!text.contains("502") && !text.contains("status"), "\(text)")
        }
    }

    @Test func theAppsOwnSentenceIsntGitHubs() {
        let text = GitHubRepoMaker.Failure.plain("Sign in with GitHub first.").localizedDescription
        #expect(text == "Sign in with GitHub first.")
        #expect(!GitHubRepoMaker.Failure.refused(status: 500, message: "").localizedDescription.contains("500"))
    }

    // 3: darkmux's own sentences stay behind Show details.

    @Test func darkmuxErrorsArePlainWithTheRawTextAsDetails() {
        let raw = DarkmuxClient.ClientError(message: "fatal: could not read Username for 'https://github.com'", status: 500)
        #expect(DarkmuxPlain.sentence(raw) == "darkmux ran into a problem. Try again in a moment.")
        #expect(DarkmuxPlain.details(raw)?.contains("fatal") == true)
        #expect(DarkmuxPlain.sentence(URLError(.cannotConnectToHost)) == "darkmux isn't answering on this Mac.")
        #expect(DarkmuxPlain.sentence(DarkmuxClient.ClientError(message: "x", status: 429)).contains("two"))
    }

    @Test func aWorkCopyFailureIsPlain() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        store.addResource(.repo, "https://github.com/kain/site", to: bot)
        let runs = RunCoordinator()
        runs.workspaceMaker = { _ in throw DarkmuxClient.ClientError(message: "fatal: could not read Username for 'https://github.com': terminal prompts disabled", status: 500) }
        await runs.setUpWorkCopy(for: bot, store: store)
        guard case let .failed(why)? = runs.workCopySetup[bot.id] else { Issue.record("not failed"); return }
        #expect(!why.contains("fatal"), "\(why)")
        #expect(runs.workCopyDetails[bot.id]?.contains("fatal") == true)
    }
}
