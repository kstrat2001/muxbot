import Foundation
import Testing
@testable import MuxBot

/// Start over (#45): darkmux's clean restart (`{"clean": true}`, darkmux
/// #3484/#3486) reinstalls the project's packages and starts the preview
/// again. Offered only when darkmux supports it, never a plain restart that
/// looks like it worked.
struct StartOverContractTests {
    @Test func aCleanStartSendsCleanTrueAndAPlainOneSendsNothingNew() throws {
        let clean = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DarkmuxClient.PreviewStart(clean: true))) as? [String: Any]
        #expect(clean?["clean"] as? Bool == true)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DarkmuxClient.PreviewStart(clean: false))) as? [String: Any]
        #expect(plain?.isEmpty == true, "a plain start's body is {}, as before")
    }

    /// darkmux with the clean restart reads the body first and refuses an
    /// unknown key (400); an older one never reads it and refuses the
    /// unknown workspace (404). Nothing starts either way.
    /// Anything else isn't an answer (sweep 2 seam #9): not cached.
    @Test(arguments: [(400, true), (404, false), (403, nil), (401, nil), (503, nil), (0, nil)] as [(Int, Bool?)])
    func theProbeTellsThemApart(status: Int, supported: Bool?) {
        #expect(DarkmuxClient.supportsCleanStart(probeStatus: status) == supported)
    }

    @Test func installProblemsPutStartOverFirst() {
        #expect(PreviewFailure(reason: "the dev server exited", log: "Error: Cannot find module './rolldown-binding.linux-arm64-musl.node'").startOverFirst)
        #expect(PreviewFailure(reason: "install failed", log: "npm error code 1").startOverFirst)
        #expect(PreviewFailure(reason: "x", log: "npm warn EBADENGINE Unsupported engine").startOverFirst)
        #expect(!PreviewFailure(reason: "x", log: "Error: listen EADDRINUSE").startOverFirst)
        #expect(!PreviewFailure(reason: "it didn't start within 15 minutes", log: nil).startOverFirst)
    }

    @Test func theCopyIsPlain() {
        #expect(PreviewFailure.startOverNote == "Reinstalls the project's packages, then starts the preview again. Your files aren't touched.")
        #expect(!PreviewFailure.startOverNote.contains("node_modules"))
    }
}

@Suite(.serialized) @MainActor
struct StartOverFlowTests {
    final class Calls: @unchecked Sendable {
        var plain = 0, clean = 0, probes = 0
    }

    private func setUp(supported: Bool) -> (Bot, RunCoordinator, Calls) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-startover-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        let calls = Calls()
        runs.previewFetcher = { start in
            if start { calls.plain += 1 }
            return LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:5000/")!)
        }
        runs.previewCleanStarter = {
            calls.clean += 1
            return LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:5002/")!)
        }
        runs.startOverProbe = {
            calls.probes += 1
            return supported
        }
        return (bot, runs, calls)
    }

    @Test func darkmuxIsAskedOnceWhetherItCanStartOver() async {
        let (_, runs, calls) = setUp(supported: true)
        #expect(runs.canStartOver == false, "unknown until asked")
        await runs.checkStartOver()
        await runs.checkStartOver()
        #expect(runs.canStartOver)
        #expect(calls.probes == 1)
    }

    @Test func startOverSendsTheCleanStartEvenWhileItRuns() async {
        let (bot, runs, calls) = setUp(supported: true)
        await runs.ensurePreview(for: bot)
        #expect(runs.livePreviews[bot.id]?.status == .ready)
        await runs.checkStartOver()
        await runs.startOver(for: bot)
        #expect(calls.clean == 1)
        #expect(calls.plain == 1, "never a plain start in its place")
        #expect(runs.livePreviews[bot.id]?.url == URL(string: "http://127.0.0.1:5002/"))
    }

    @Test func anOlderDarkmuxGetsNoStartOverAtAll() async {
        let (bot, runs, calls) = setUp(supported: false)
        await runs.ensurePreview(for: bot)
        await runs.checkStartOver()
        #expect(!runs.canStartOver)
        await runs.startOver(for: bot)
        #expect(calls.clean == 0)
        #expect(calls.plain == 1, "no plain restart dressed up as Start over")
    }

    @Test func aStartOverThatKeepsTheURLStillReloadsThePage() async {
        let (bot, runs, _) = setUp(supported: true)
        runs.previewCleanStarter = { LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:5000/")!) }
        await runs.ensurePreview(for: bot)
        await runs.checkStartOver()
        await runs.startOver(for: bot)
        #expect(runs.previewReloads[bot.id] == 1)
    }
}
