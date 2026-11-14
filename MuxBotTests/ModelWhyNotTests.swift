import Testing
@testable import MuxBot

/// A model that can't run now is listed grayed with why, in plain words:
/// never hidden, and never darkmux's reason as is (it can name a command).
struct ModelWhyNotTests {
    typealias P = DarkmuxClient.ProfileInfo

    @Test func flintBehindRecsOwnServerSaysWhyWithoutACommand() {
        let reason = "rec's own server is up or starting (at http://127.0.0.1:11500), and rec runs one server per machine; darkmux never stops or takes over a server it did not start. Run `rec stop`, then dispatch again"
        let flint = P(name: "flint-managed", description: nil, model: "flint-int4", endpoint: "flint", reachable: false, loaded: false,
                      availability: .init(state: "unavailable", reason: reason))
        #expect(!ModelLabel.canRun(flint))
        let why = ModelLabel.whyNot(flint) ?? ""
        #expect(why.contains("own server"))
        #expect(!why.contains("`") && !why.contains("rec stop"), "no command in the app")
        let row = ModelRow(name: "flint-managed", listed: [flint], listing: .listed)
        #expect(row.detail == why)
    }

    @Test func runnableModelsHaveNoReason() {
        let up = P(name: "q", description: nil, model: "qwen3.8-27b", endpoint: "lmstudio", reachable: true, loaded: true,
                   availability: .init(state: "startable", reason: nil))
        #expect(ModelLabel.canRun(up))
        #expect(ModelLabel.whyNot(up) == nil)
        let down = P(name: "d", description: nil, model: "x", endpoint: "url", reachable: false, loaded: nil)
        #expect(ModelLabel.whyNot(down) != nil)
    }
}
