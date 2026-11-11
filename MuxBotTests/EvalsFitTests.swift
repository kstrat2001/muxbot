import Foundation
import Testing
@testable import MuxBot

/// The Fit order: the model list sorted by how setups on this chip did on the
/// public evals, never a number shown; models without runs keep darkmux's order.
struct EvalsFitTests {
    func p(_ name: String, _ model: String, _ endpoint: String = "lmstudio") -> DarkmuxClient.ProfileInfo {
        DarkmuxClient.ProfileInfo(name: name, description: nil, model: model, endpoint: endpoint, reachable: true, loaded: true)
    }

    @Test func theChipIsTheSitesSlug() {
        #expect(EvalsFit.chipSlug("Apple M5 Max") == "apple-m5-max")
        #expect(EvalsFit.chipSlug("  Apple M2 (Asahi) ") == "apple-m2-asahi")
        #expect(EvalsFit.url(chip: "Apple M5 Max").absoluteString == "https://evals.darkmux.com/api/v1/frontier?machine=apple-m5-max&providers=false")
    }

    @Test(arguments: [
        ("mlx-community/Qwen3.8-27B-4bit", "qwen3.8-27b"),
        ("qwen/qwen3.8-27b", "qwen3.8-27b"),
        ("darkmux:qwen3.6-35b-a3b-turboquant-mlx", "qwen3.6-35b-a3b"),
        ("unsloth/Devstral-Small-q4_k_m", "devstral-small"),
        ("flint-int4", "flint-int4"),
        ("qwen3-coder-next-mlx", "qwen3-coder-next"),
    ])
    func theSameWeightsAreOneFamily(model: String, family: String) {
        #expect(EvalsFit.family(model) == family)
    }

    @Test func theSitesOrderFirstThenDarkmuxsOrder() throws {
        let json = #"{"data":{"points":[{"family":"qwen3.8-27b"},{"family":"gpt-oss-120b"},{"family":"qwen3.8-27b"}]},"meta":{}}"#
        let fit = try EvalsFit.families(from: Data(json.utf8))
        #expect(fit == ["qwen3.8-27b", "gpt-oss-120b"])
        let listed = [p("phi", "phi-4"), p("big", "gpt-oss-120b"), p("fold", "mlx-community/Qwen3.8-27B-4bit", "tensorfold"), p("other", "devstral")]
        #expect(EvalsFit.ordered(listed, by: fit).map(\.name) == ["fold", "big", "phi", "other"])
        #expect(EvalsFit.ordered(listed, by: []).map(\.name) == listed.map(\.name), "no data: darkmux's order")
    }
}

@Suite(.serialized) @MainActor
struct EvalsFitLoadTests {
    @Test func aFailedReadLeavesDarkmuxsOrderAndTriesAgain() async {
        let brain = BotBrain()
        struct Down: Error {}
        brain.runs.fitSource = { throw Down() }
        await brain.runs.loadFitOrder()
        #expect(brain.runs.fitOrder.isEmpty)
        brain.runs.fitSource = { Data(#"{"data":{"points":[{"family":"phi-4"}]}}"#.utf8) }
        await brain.runs.loadFitOrder()
        #expect(brain.runs.fitOrder == ["phi-4"])
    }
}
