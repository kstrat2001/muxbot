import Testing
@testable import MuxBot

/// A model that can't run now is listed grayed with why, in plain words:
/// never hidden, and never darkmux's reason as is (it can name a command).
struct ModelWhyNotTests {
    typealias P = DarkmuxClient.ProfileInfo

    /// (darkmux #3574) The code decides, never the reason's words: a reason
    /// that names rec's own server with no code is the general sentence,
    /// and a code with any reason gets its own.
    @Test func theCodeDecidesNeverTheReason() {
        let reason = "rec's own server is up or starting (at http://127.0.0.1:11500), and rec runs one server per machine; darkmux never stops or takes over a server it did not start. Run `rec stop`, then dispatch again"
        let noCode = P(name: "flint-managed", description: nil, model: "flint-int4", endpoint: "flint", reachable: false, loaded: false,
                       availability: .init(state: "unavailable", reason: reason))
        #expect(ModelLabel.whyNot(noCode) == "darkmux can't start this model on this Mac right now.")
        let flint = P(name: "flint-managed", description: nil, model: "flint-int4", endpoint: "flint", reachable: false, loaded: false,
                      availability: .init(state: "unavailable", reason: reason, code: "engine_in_use"))
        let why = ModelLabel.whyNot(flint) ?? ""
        #expect(why.contains("own server"))
        #expect(!why.contains("`") && !why.contains("rec stop"), "no command in the app")
        let row = ModelRow(name: "flint-managed", listed: [flint], listing: .listed)
        #expect(row.detail == why)
    }

    /// Every code darkmux gives a model's availability has its own plain
    /// sentence, with no command and none of darkmux's words; a code this
    /// app doesn't know yet gets the general one.
    @Test func eachCodeHasItsOwnPlainSentence() {
        func why(_ code: String?) -> String {
            ModelLabel.whyNot(P(name: "m", description: nil, model: "m", endpoint: "flint", reachable: false, loaded: false,
                                availability: .init(state: "unavailable", reason: "Run `x`", code: code))) ?? ""
        }
        let codes = ["engine_in_use", "port_in_use", "engine_unavailable", "model_start_failed", "wont_fit", "memory_in_use", "busy"]
        let sentences = codes.map(why)
        #expect(Set(sentences).count == codes.count, "one sentence each")
        for s in sentences + [why("something_new")] {
            #expect(!s.isEmpty && !s.contains("`") && !s.contains("_"))
        }
        #expect(why("something_new") == why(nil))
    }

    @Test func runnableModelsHaveNoReason() {
        let up = P(name: "q", description: nil, model: "qwen3.8-27b", endpoint: "lmstudio", reachable: true, loaded: true,
                   availability: .init(state: "startable", reason: nil))
        #expect(ModelLabel.canRun(up))
        #expect(ModelLabel.whyNot(up) == nil)
        let down = P(name: "d", description: nil, model: "x", endpoint: "url", reachable: false, loaded: nil)
        #expect(ModelLabel.whyNot(down) != nil)
    }

    /// (darkmux #3574) darkmux never stops rec's own server: a model it
    /// holds back stays grayed, with a reason and no command.
    @Test func aModelBehindItsEnginesOwnServerStaysGrayed() {
        let flint = P(name: "flint-managed", description: nil, model: "flint-int4", endpoint: "flint", reachable: false, loaded: false,
                      availability: .init(state: "unavailable", reason: "held", code: "engine_in_use"))
        #expect(!ModelLabel.canRun(flint))
        let why = ModelLabel.whyNot(flint) ?? ""
        #expect(why.contains("own server") && !why.contains("`") && !why.contains("approve"))
    }
}
