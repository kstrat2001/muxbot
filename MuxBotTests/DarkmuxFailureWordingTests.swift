import Foundation
import Testing
@testable import MuxBot

/// Every way a darkmux call can fail reads as one plain sentence with
/// something to do, never Foundation's or darkmux's raw words.
struct DarkmuxFailureWordingTests {
    @Test func everyCodedFailureSaysWhatToDo() {
        for code in ["model_start_failed", "model_stop_failed", "port_in_use", "engine_unavailable", "engine_in_use", "busy", "wont_fit"] {
            let line = RunResultText.failure(code: code, error: "", reason: nil)
            #expect(line.contains("again") || line.contains("Pick") || line.contains("pick"), "\(code): \(line)")
        }
    }

    @Test func aSlowDarkmuxIsNotADownDarkmux() {
        #expect(DarkmuxPlain.sentence(URLError(.timedOut)) == "darkmux took too long to answer. Try again in a moment.")
    }

    @Test func anAnswerTheAppCantReadIsPlain() {
        struct Shape: Decodable { var status: String }
        let error = #expect(throws: DecodingError.self) { try JSONDecoder().decode(Shape.self, from: Data("{}".utf8)) }
        guard let error else { return }
        #expect(DarkmuxPlain.sentence(error).hasPrefix("darkmux answered in a way"))
        #expect(DarkmuxPlain.details(error)?.contains("status") == true)
    }

    @Test func aSubmitDarkmuxNeverAnsweredSaysSo() {
        guard case let .fail(reason, _) = RunCoordinator.startFailure(URLError(.cannotConnectToHost)) else { Issue.record("expected .fail"); return }
        #expect(reason.hasPrefix("darkmux isn't answering on this Mac."))
    }

    @Test func aSubmitDarkmuxRefusedPointsAtDetails() {
        let refused = DarkmuxClient.ClientError(message: "profile x is not in this machine's clients.profiles", status: 403, code: "forbidden")
        guard case let .fail(reason, details) = RunCoordinator.startFailure(refused) else { Issue.record("expected .fail"); return }
        #expect(reason == "darkmux didn't start it. Show details has why.")
        #expect(details?.contains("clients.profiles") == true)
    }

    @Test func anEngineThatWouldntLetGoSaysSo() {
        let error = DarkmuxClient.EngineNotFreed(underlying: URLError(.timedOut))
        guard case let .fail(reason, _) = RunCoordinator.startFailure(error) else { Issue.record("expected .fail"); return }
        #expect(reason.hasPrefix("darkmux couldn't stop the model's own server"))
    }

    @MainActor @Test func darkmuxNotAnsweringInAGitHubFlowIsNamedAsDarkmux() {
        let said = RunCoordinator.plain(DarkmuxClient.Unreachable(underlying: URLError(.cannotConnectToHost)))
        #expect(said.sentence.hasPrefix("darkmux isn't answering"))
    }
}
