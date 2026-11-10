#if os(macOS)
import AppKit
import SwiftUI
import Testing
import WebKit
@testable import MuxBot

/// Sweep batch 4: the preview recovers and says why.
@Suite(.serialized) @MainActor
struct PreviewSweepTests {
    private func setUp() -> (BotStore, Bot, RunCoordinator) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-sweep4-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        runs.previewDeadline = 4
        return (store, bot, runs)
    }

    private func ready(_ port: Int = 5000) -> LivePreview { LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:\(port)/")!) }

    private func page(_ title: String) -> URL {
        URL(string: "data:text/html;base64," + Data("<!doctype html><title>\(title)</title><body><h1 id=t>\(title)</h1></body>".utf8).base64EncodedString())!
    }

    private func host(_ preview: PreviewController) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreviewPerBotTests.PreviewHost(preview: preview))
        window.orderFrontRegardless()
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        return window
    }

    private func settle(_ preview: PreviewController) async throws {
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<100 where preview.page.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // 3: home, off-origin, header.

    @Test func homeLoadsThePreviewAgainFromAnywhere() async throws {
        let preview = PreviewController()
        let window = host(preview)
        defer { window.close() }
        preview.show(page("Home"), for: UUID())
        try await settle(preview)
        _ = preview.page.load(URLRequest(url: page("Elsewhere")))   // the page went somewhere else
        try await settle(preview)
        #expect(try await preview.page.callJavaScript("return document.title") as? String == "Elsewhere")
        preview.goHome()
        try await settle(preview)
        #expect(try await preview.page.callJavaScript("return document.title") as? String == "Home")
    }

    @Test func offOriginLinksLeaveThePreview() {
        let home = URL(string: "http://127.0.0.1:5000/")!
        #expect(PreviewNavigation.opensElsewhere(URL(string: "https://github.com/kstrat2001")!, home: home))
        #expect(!PreviewNavigation.opensElsewhere(URL(string: "http://127.0.0.1:5000/about")!, home: home))
        #expect(PreviewNavigation.opensElsewhere(URL(string: "http://127.0.0.1:6000/")!, home: home), "another port is another site")
    }

    // 4: picking survives loads.

    @Test func pickWaitsForThePageAndSurvivesAReload() async throws {
        let preview = PreviewController()
        let window = host(preview)
        defer { window.close() }
        let bot = UUID()
        preview.startPicking(for: bot)   // the chip, before the page is there
        preview.show(page("Site"), for: bot)
        try await settle(preview)
        try await Task.sleep(for: .milliseconds(300))
        #expect(preview.isPicking)
        #expect(try await preview.page.callJavaScript("return !!window.__muxPick") as? Bool == true, "picking works once it loaded")
        preview.reload()
        try await settle(preview)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await preview.page.callJavaScript("return !!window.__muxPick") as? Bool == true, "and after a reload")
    }

    // 6: a pick sent during a Tweak.

    @Test func aPickRidesAlongWithATweak() {
        let change = RunCoordinator.tweakChange("make this bigger", element: PickedElement.fixture)
        #expect(change.contains("make this bigger"))
        #expect(change.contains("main > section.hero > h1"))
    }

    // 9: the done-when check reports.

    @Test func aCheckThatCantMeasureSaysSoAndRetriesWhenThePreviewIsReady() async throws {
        let (store, bot, runs) = setUp()
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        run.changedFiles = ["a.css +1 −0"]
        runs.checkSpecs[run.id] = LayoutCheck.Spec(page: URL(string: "http://127.0.0.1:5000/")!, overflowWidths: [820])
        let probe = MockProbe([:])
        runs.layoutProbe = probe
        runs.previewFetcher = { _ in LivePreview(status: .failed("the dev server exited")) }
        await runs.check(run)
        #expect(runs.checkProblems[run.id] == RunCoordinator.checkNotRunning)
        probe.facts = [820: heroAt(820), 768: heroAt(768)]
        runs.previewFetcher = { [self] _ in ready(5100) }
        await runs.ensurePreview(for: bot)
        await until { runs.runChecks[run.id] != nil }
        #expect(runs.runChecks[run.id] != nil, "checked once the preview was there")
        #expect(probe.asked.last?.url.port == 5100, "on the preview's current address")
    }

    // 10 + 14: polls tolerate a hiccup; stops always go out.

    @Test func oneFailedStatusCallDoesNotFailThePreview() async {
        let (_, bot, runs) = setUp()
        let calls = Recorder()
        runs.previewFetcher = { start in
            calls.add(start ? "start" : "status")
            if start { return LivePreview(status: .starting) }
            if calls.values.filter({ $0 == "status" }).count == 1 { throw URLError(.networkConnectionLost) }
            return LivePreview(status: .ready, url: URL(string: "http://127.0.0.1:5000/")!)
        }
        await runs.ensurePreview(for: bot)
        #expect(runs.livePreviews[bot.id]?.status == .ready)
    }

    @Test func aFailedPreviewIsStillStopped() async {
        let (_, bot, runs) = setUp()
        runs.previewFetcher = { _ in LivePreview(status: .failed("the dev server exited")) }
        await runs.ensurePreview(for: bot)
        let stopped = Recorder()
        runs.previewStopper = { stopped.add($0) }
        await runs.stopPreview(for: bot)
        #expect(stopped.values == ["site-1"])
    }

    @Test func leavingWhileItStartsStillStopsIt() async {
        let (_, bot, runs) = setUp()
        let stopped = Recorder()
        runs.previewStopper = { stopped.add($0) }
        runs.previewFetcher = { start in
            if !start { try await Task.sleep(for: .seconds(5)) }
            return LivePreview(status: .starting)
        }
        let starting = Task { await runs.ensurePreview(for: bot) }
        try? await Task.sleep(for: .milliseconds(200))
        starting.cancel()
        await starting.value
        await runs.stopPreview(for: bot)
        #expect(stopped.values == ["site-1"], "the DELETE goes out though the start was cancelled")
    }

    // 11: darkmux not running.

    @Test func darkmuxNotAnsweringIsSaidPlainly() async {
        let (_, bot, runs) = setUp()
        runs.previewFetcher = { _ in throw URLError(.cannotConnectToHost) }
        await runs.ensurePreview(for: bot)
        #expect(runs.livePreviews[bot.id]?.status == .unavailable(.notAnswering))
    }

    // 12 + 13: a preview that went away is noticed; a cached ready is checked.

    @Test func theHeartbeatNoticesDarkmuxGoingAway() async {
        let (_, bot, runs) = setUp()
        runs.previewFetcher = { [self] _ in ready() }
        await runs.ensurePreview(for: bot)
        runs.previewHeartbeat = .milliseconds(20)
        runs.previewFetcher = { _ in throw URLError(.cannotConnectToHost) }
        let beat = Task { await runs.keepPreviewAlive(for: bot) }
        await until { runs.livePreviews[bot.id]?.status != .ready }
        beat.cancel()
        #expect(runs.livePreviews[bot.id]?.status == .unavailable(.notAnswering))
    }

    @Test func aStaleReadyIsCheckedAndRestarted() async {
        let (_, bot, runs) = setUp()
        runs.previewFetcher = { [self] _ in ready(5000) }
        await runs.ensurePreview(for: bot)
        // darkmux restarted meanwhile: it no longer has the preview, and a
        // new start runs it on another port.
        runs.previewFetcher = { [self] start in
            if !start { throw DarkmuxClient.ClientError(message: "no preview for site-1", status: 404) }
            return ready(5200)
        }
        await runs.ensurePreview(for: bot)
        #expect(runs.livePreviews[bot.id]?.url?.port == 5200)
    }

    // 16: Add folder says what happened.

    @Test func aWorkCopyThatCantBeMadeIsSaidOnTheCard() async throws {
        let (store, bot, runs) = setUp()
        runs.workspaceMaker = { _ in throw DarkmuxClient.ClientError(message: "fetch failed", status: 422) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("addfolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let problem = await runs.addFolder(dir, to: bot, store: store)
        #expect(problem != nil, "the failure is on the card")
    }

    // 17: checking a new recipe in plain words.

    @Test func aRecipeCheckSaysWhyInPlainWords() async {
        let (store, bot, _) = setUp()
        let brain = BotBrain()
        brain.runs.connection = setUp().2.connection
        brain.runs.previewFetcher = { _ in LivePreview(status: .failed("install (npm ci) exited with exit status: 1"), log: "npm error code ERESOLVE /Users/x") }
        await brain.checkPreview(bot, store: store)
        let line = (store.conversation(for: .bot(bot.id)).messages ?? []).last?.content ?? ""
        #expect(!line.contains("/Users/") && !line.contains("exit status"), "\(line)")
        #expect(line.contains(PreviewFailure(reason: "install (npm ci) exited with exit status: 1", log: nil).explanation), "\(line)")
    }

    // Seam 9: darkmux's real reasons.

    @Test(arguments: [
        ("a preview runs in a container: darkmux's runtime requires Docker, which isn't running", PreviewFailure.Kind.docker),
        ("the preview container did not start (exit 125)", .containerFailed),
        ("install (pnpm install) exited with exit status: 1", .installFailed),
        ("the preview's container stopped itself: darkmux stopped answering", .serverStopped),
        ("the dev server listens on 127.0.0.1 inside its container; set it to bind 0.0.0.0", .loopbackOnly),
        ("the dev server didn't answer on port 5173 within 3 minutes", .notAnswering),
    ])
    func darkmuxsReasonsAreRecognized(reason: String, kind: PreviewFailure.Kind) {
        #expect(PreviewFailure(reason: reason, log: nil).kind == kind, "\(reason)")
    }

    // Seam 10: darkmux's code, not its wording.

    @Test func templateAndCheckoutCasesComeFromTheCode() {
        #expect(LivePreview.Unavailable.from(status: 404, message: "the template this project was made from had no .darkmux/preview.json", template: true, code: "template_no_recipe") == .templateNoRecipe)
        #expect(LivePreview.Unavailable.from(status: 404, message: "not made from a checkout of yours", template: true, code: "no_source_checkout") == .remakeProject)
        #expect(LivePreview.Unavailable.from(status: 404, message: "the workspace is no longer a worktree of your checkout", template: false, code: "no_source_checkout") == .checkoutMoved)
        #expect(LivePreview.Unavailable.from(status: 404, message: "no .darkmux/preview.json in your checkout", template: false, code: "no_recipe") == .noRecipe)
    }

    @Test func theClientErrorCarriesTheCode() async {
        DarkmuxStub.status = 404
        DarkmuxStub.body = #"{"error":"no recipe","code":"template_no_recipe"}"#
        defer { DarkmuxStub.body = nil }
        var client = DarkmuxClient()
        client.session = DarkmuxStub.session
        do { _ = try await client.startPreview(token: "t", workspace: "w"); Issue.record("expected a refusal") }
        catch let error as DarkmuxClient.ClientError { #expect(error.code == "template_no_recipe") }
        catch { Issue.record("\(error)") }
    }

    // State 9: a new work copy stops the old preview.

    @Test func aNewWorkCopyStopsTheOldPreview() async {
        let (store, bot, runs) = setUp()
        runs.previewFetcher = { [self] _ in ready() }
        await runs.ensurePreview(for: bot)
        let stopped = Recorder()
        runs.previewStopper = { stopped.add($0) }
        runs.workspaceMaker = { _ in try JSONDecoder().decode(DarkmuxClient.Workspace.self, from: Data(#"{"workspace":"site-2"}"#.utf8)) }
        store.addResource(.repo, "https://github.com/kstrat2001/site", to: bot)
        await runs.setUpWorkCopy(for: bot, store: store)
        #expect(stopped.values == ["site-1"])
        #expect(runs.livePreviews[bot.id] == nil)
    }
}
#endif
