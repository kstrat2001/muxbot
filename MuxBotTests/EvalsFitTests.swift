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
        ("flint-int4", "flint"),
        ("RecursiveSI/flint-int4", "flint"),
        ("qwen3-coder-next-mlx", "qwen3-coder-next"),
    ])
    func theSameWeightsAreOneFamily(model: String, family: String) {
        #expect(EvalsFit.family(model) == family)
    }

    @Test func theSitesOrderFirstThenDarkmuxsOrder() throws {
        let json = #"{"data":{"points":[{"family":"qwen3.8-27b"},{"family":"gpt-oss-120b"},{"family":"qwen3.8-27b"}]},"meta":{}}"#
        let fit = try EvalsFit.order(from: Data(json.utf8))
        #expect(fit.families == ["qwen3.8-27b", "gpt-oss-120b"])
        let listed = [p("phi", "phi-4"), p("big", "gpt-oss-120b"), p("fold", "mlx-community/Qwen3.8-27B-4bit", "tensorfold"), p("other", "devstral")]
        #expect(EvalsFit.ordered(listed, by: fit).map(\.name) == ["fold", "big", "phi", "other"])
        #expect(EvalsFit.ordered(listed, by: EvalsFit.Order()).map(\.name) == listed.map(\.name), "no data: darkmux's order")
    }

    @Test func theSitesIdsMatchAndNameTheModel() throws {
        // The owner aliased rec's flint-int4 to "Flint"; the frontier lists both ids.
        let json = #"{"data":{"points":[{"family":"qwen3.8-27b","model":"Qwen3.8 27B","ids":["qwen/qwen3.8-27b"]},{"family":"flint","model":"Flint","ids":["Flint","RecursiveSI/flint-int4"]}]}}"#
        let fit = try EvalsFit.order(from: Data(json.utf8))
        let listed = [p("turbo", "qwen3.8-27b-turboquant-mlx"), p("flint", "flint-int4", "flint"), p("qwen", "qwen3.8-27b")]
        #expect(EvalsFit.ordered(listed, by: fit).map(\.name) == ["turbo", "qwen", "flint"], "a family match still sorts")
        #expect(fit.name("darkmux:flint-int4") == "Flint")
        #expect(fit.name("qwen3.8-27b") == "Qwen3.8 27B")
        #expect(fit.name("qwen3.8-27b-turboquant-mlx") == nil, "another conversion keeps its own id")
        #expect(fit.name("phi-4") == nil)
    }

    @Test func recsFlintMatchesItsEvalsRuns() throws {
        // Evals runs name rec's model `flint` (quant int4); darkmux lists it as `flint-int4`.
        for site in ["flint", "flint-int4"] {
            let fit = try EvalsFit.order(from: Data(#"{"data":{"points":[{"family":"\#(site)"}]}}"#.utf8))
            let listed = [p("qwen", "qwen3.8-27b"), p("flint", "flint-int4", "flint")]
            #expect(EvalsFit.ordered(listed, by: fit).map(\.name) == ["flint", "qwen"])
        }
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
        #expect(brain.runs.fitOrder.families == ["phi-4"])
    }
}
