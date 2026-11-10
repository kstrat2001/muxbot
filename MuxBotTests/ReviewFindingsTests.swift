import Foundation
import Testing
@testable import MuxBot

/// Fixes from the code review of 2026-11-10: the run loop.
@Suite(.serialized) @MainActor
struct ReviewFindingsRunTests {
    private func setUp() -> (BotStore, Bot, RunCoordinator) {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        bot.workspaceName = "site-1"
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let defaults = UserDefaults(suiteName: "muxbot-tests-findings-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let runs = RunCoordinator()
        runs.connection = FleetConnection(keychain: keychain, defaults: defaults)
        runs.pollInterval = 0.02
        runs.profileSource = { [] }
        runs.deviceRuns = true
        runs.useOnDeviceModel = false
        return (store, bot, runs)
    }

    private func status(_ json: String) -> DarkmuxClient.WorkStatus {
        try! JSONDecoder().decode(DarkmuxClient.WorkStatus.self, from: Data(json.utf8))
    }

    private func said(_ store: BotStore, _ bot: Bot) -> [String] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }.map(\.content)
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func running(_ store: BotStore, _ bot: Bot, _ runs: RunCoordinator, workId: String) -> BotRun {
        let run = store.proposeRun(task: "Make it warm", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        run.darkmuxWorkId = workId
        runs.markStartedHere(run)
        runs.recordWork(workId, for: run)
        return run
    }

    // 1: "Waiting for a free slot" is said once, however often darkmux
    // refuses the retry.

    @Test func waitingForASlotIsSaidOnce() async {
        let (store, bot, runs) = setUp()
        runs.queueRetryInterval = .milliseconds(20)
        let calls = Recorder()
        runs.workSubmitter = { _, _, _, _, _ in
            calls.add("submit")
            if calls.values.count < 5 { throw DarkmuxClient.ClientError(message: "too many", status: 429) }
            return ("w-9", nil)
        }
        runs.workStatusFetcher = { [self] _ in status(#"{"status":"running"}"#) }
        let run = store.proposeRun(task: "third", crew: .coder, on: bot)
        runs.decide(.approve, on: run, store: store)
        await until { run.darkmuxWorkId == "w-9" }
        #expect(run.darkmuxWorkId == "w-9")
        #expect(calls.values.count == 5, "refused four times, then accepted")
        #expect(said(store, bot).filter { $0 == RunCoordinator.waitingForSlot }.count == 1, "\(said(store, bot))")
        run.phase = .canceled
    }

    @Test func aRefusedRetryKeepsItsPlaceInLine() async {
        let (store, bot, runs) = setUp()
        runs.queueRetryInterval = .seconds(60)
        let order = Recorder()
        let open = Counter()
        runs.workSubmitter = { _, message, _, _, _ in
            let task = message.hasPrefix("first") ? "first" : "second"
            order.add(task)
            if open.count == 0 { throw DarkmuxClient.ClientError(message: "too many", status: 429) }
            return ("w-\(task)", nil)
        }
        runs.workStatusFetcher = { [self] _ in status(#"{"status":"running"}"#) }
        let first = store.proposeRun(task: "first", crew: .coder, on: bot)
        runs.decide(.approve, on: first, store: store)
        await until { order.values.count == 1 }
        let other = store.add(name: "other", instructions: "")
        other.workspaceName = "other-1"
        let second = store.proposeRun(task: "second", crew: .coder, on: other)
        runs.decide(.approve, on: second, store: store)
        await until { order.values.count == 2 }
        // A retry darkmux refuses again: "first" stays ahead of "second".
        runs.slotFreed(store: store)
        await until { order.values.count == 3 }
        try? await Task.sleep(for: .milliseconds(50))
        open.add()
        runs.slotFreed(store: store)
        await until { order.values.count == 4 }
        #expect(order.values == ["first", "second", "first", "first"], "\(order.values)")
        first.phase = .canceled
        second.phase = .canceled
    }

    // a: a finished run's slot is free before its backup to GitHub is done.

    @Test func theSlotIsFreeBeforeTheBackupFinishes() async {
        let (store, bot, runs) = setUp()
        store.addResource(.repo, "https://github.com/kain/site", to: bot)
        bot.githubStart = GitHubPR.Start(commit: "start1", branch: "main", head: "mux/site")
        runs.githubToken = { "ghu_abc" }
        runs.noticePoster = { _, _ in }
        runs.changesFetcher = { _ in
            DarkmuxClient.Changes(base: "local0", baseBranch: "main", head: "h", branch: "main",
                                  files: [.init(path: "a.css", mode: "100644", content: "YQo=", deleted: nil)])
        }
        let started = Counter(), finished = Counter()
        runs.prPusher = { _, _, _, _, _ in
            started.add()
            try? await Task.sleep(for: .milliseconds(400))
            finished.add()
            return GitHubPR.Pushed(commit: "c1")
        }
        let run = running(store, bot, runs, workId: "w-1")
        runs.workStatusFetcher = { [self] _ in
            status(#"{"status":"done","commit":"c1","branch":"main","changes":{"files":[{"path":"a.css","added":1,"removed":0}]}}"#)
        }
        await runs.follow(run, workId: "w-1", store: store)
        #expect(run.phase == .result)
        #expect(finished.count == 0, "following ended (and freed the slot) while GitHub was still busy")
        await until { finished.count == 1 }
        #expect(started.count == 1 && finished.count == 1, "and the backup still happened")
    }

    // 6: what a running run is doing, and statuses this app doesn't know.

    @Test func theStatusCarriesWhatTheRunIsDoing() {
        #expect(status(#"{"status":"running","activity":"starting_model","activity_elapsed_ms":1200}"#).activity == "starting_model")
        #expect(RunCoordinator.RunActivity(status: status(#"{"status":"running","activity":"starting_model"}"#)) == .startingModel)
        #expect(RunCoordinator.RunActivity(status: status(#"{"status":"running","activity":"queued"}"#)) == .queued)
        #expect(RunCoordinator.RunActivity(status: status(#"{"status":"running"}"#)) == nil)
        // A value from a newer darkmux, or one that isn't text: nothing shown, never a failed decode.
        #expect(RunCoordinator.RunActivity(status: status(#"{"status":"running","activity":"warming_up"}"#)) == nil)
        #expect(status(#"{"status":"running","activity":7}"#).activity == nil)
        #expect(RunCoordinator.RunActivity.startingModel.line == "Starting the model…")
        #expect(RunCoordinator.RunActivity.queued.line == "Waiting for the model to be free…")
    }

    @Test func theLiveRunKnowsItsActivityUntilItEnds() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs, workId: "w-1")
        let step = Counter()
        runs.workStatusFetcher = { [self] _ in
            step.add()
            switch step.count {
            case ...3: return status(#"{"status":"running","activity":"starting_model"}"#)
            case 4...8: return status(#"{"status":"running","activity":"queued"}"#)
            case 9...12: return status(#"{"status":"running"}"#)
            default: return status(#"{"status":"done","changes":{"files":[]}}"#)
            }
        }
        var seen: [RunCoordinator.RunActivity?] = []
        let following = Task { await runs.follow(run, workId: "w-1", store: store) }
        while run.phase == .running, step.count < 40 {
            let now = runs.runActivity[run.id]
            if seen.isEmpty || seen.last! != now { seen.append(now) }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await following.value
        #expect(seen.contains(.startingModel) && seen.contains(.queued), "\(seen)")
        #expect(run.phase == .result)
        #expect(runs.runActivity[run.id] == nil, "cleared when the run ends")
        _ = bot
    }

    @Test func anUnknownStatusKeepsPollingAndIsNeverAFailure() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs, workId: "w-1")
        let step = Counter()
        runs.workStatusFetcher = { [self] _ in
            step.add()
            return step.count < 4 ? status(#"{"status":"finishing_up"}"#) : status(#"{"status":"done","changes":{"files":[]}}"#)
        }
        await runs.follow(run, workId: "w-1", store: store)
        #expect(step.count == 4, "asked again until darkmux said it ended")
        #expect(run.phase == .result, "\(run.phase)")
        _ = bot
    }

    @Test func anErrorIsStillAFailure() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs, workId: "w-1")
        runs.workStatusFetcher = { [self] _ in status(#"{"status":"error","error":"model crashed","reason":"error","code":"dispatch_failed"}"#) }
        await runs.follow(run, workId: "w-1", store: store)
        #expect(run.phase == .failed)
        _ = bot
    }

    @Test func aStopWaitsThroughAnUnknownStatusForTheRealEnd() async {
        let (store, bot, runs) = setUp()
        let run = running(store, bot, runs, workId: "w-1")
        let step = Counter()
        runs.workCanceller = { _ in }
        runs.workStatusFetcher = { [self] _ in
            step.add()
            return step.count < 3 ? status(#"{"status":"winding_down"}"#)
                : status(#"{"status":"cancelled","reason":"cancelled","commit":"c9","branch":"mux/site","files":["a.css"]}"#)
        }
        await runs.stop(run, store: store)
        #expect(run.phase == .canceled)
        await until { run.keptCommit == "c9" }
        #expect(run.keptCommit == "c9", "what it left behind is kept once darkmux says it ended")
        _ = bot
    }
}

/// 3: a UI-test launch is isolated like a unit test.
@Suite struct ReviewFindingsIsolationTests {
    @Test func aUITestLaunchCountsAsTesting() {
        #expect(TestIsolation.isUITest(arguments: ["Mux Bot", "-uiTesting", "-openBot", "My website"]))
        #expect(TestIsolation.isUITest(arguments: ["Mux Bot", "-uiTestingEmpty"]))
        #expect(!TestIsolation.isUITest(arguments: ["Mux Bot", "-openBot", "uiTesting"]))
        #expect(TestIsolation.isTesting && TestIsolation.isUnitTesting)
    }

    @Test func aUITestLaunchHasItsOwnKeychainItemAndDefaults() {
        #expect(TestIsolation.uiTestKeychainService != "com.darklyenergized.darkmuxapp")
        #expect(TestIsolation.uiTestKeychainService != KeychainHelper.defaultService, "apart from the unit tests' too")
        #expect(TestIsolation.uiTestDefaultsSuite != "muxbot-tests-app")
    }

    @Test func modelSettingsAreNeverICloudUnderTests() {
        let backing = ModelSettingsStore.shared.backing
        #expect(!(backing is NSUbiquitousKeyValueStore))
        #expect(backing !== UserDefaults.standard)
    }
}

/// 4 and 8: the darkmux client under tests, and a refused token.
@Suite(.serialized) @MainActor
struct ReviewFindingsClientTests {
    @Test func theDefaultClientNeverReachesTheNetworkUnderTests() async {
        #expect(DarkmuxClient.defaultSession !== URLSession.shared)
        #expect(DarkmuxClient.defaultSession.configuration.protocolClasses?.first == NoNetworkProtocol.self)
        do {
            _ = try await DarkmuxClient().workStatus(token: "t0ken", workId: "w-1")
            Issue.record("a request went somewhere")
        } catch let error as URLError {
            #expect(error.code == .cannotConnectToHost)
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func aPairedConnectionsClientIsTheNoNetworkOneByDefault() {
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let connection = FleetConnection(keychain: keychain, defaults: UserDefaults(suiteName: "muxbot-tests-client-\(UUID().uuidString)")!)
        #expect(connection.client.session === DarkmuxClient.defaultSession)
    }

    // 8: a late 401 for an old token never erases a new pairing.

    @Test func aLate401ForAnOldTokenKeepsTheNewPairing() async throws {
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "old-token"
        let defaults = UserDefaults(suiteName: "muxbot-tests-client-\(UUID().uuidString)")!
        defaults.set("Mux Bot", forKey: "darkmux.client.name")
        let connection = FleetConnection(keychain: keychain, defaults: defaults)
        var shown = false
        connection.onRevoked = { shown = true }
        connection.client.session = ClientStub.session
        // Paired again while a request with the old token was still out.
        connection.completePairing(token: "new-token", name: "Mux Bot")
        ClientStub.status = 401
        _ = try? await connection.client.workStatus(token: "old-token", workId: "w-1")
        try await Task.sleep(for: .milliseconds(80))
        #expect(connection.token == "new-token")
        #expect(connection.isPaired)
        #expect(!shown)
        // The current token refused: that is a revoked pairing.
        _ = try? await connection.client.workStatus(token: "new-token", workId: "w-1")
        for _ in 0..<50 where connection.token != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(connection.token == nil)
        #expect(connection.state == .failed(FleetConnection.revokedMessage))
        #expect(shown)
    }

    @Test func theRefusedTokenComesFromTheRequest() {
        #expect(DarkmuxClient.bearerToken("Bearer abc") == "abc")
        #expect(DarkmuxClient.bearerToken("Basic abc") == nil)
        #expect(DarkmuxClient.bearerToken("Bearer ") == nil)
        #expect(DarkmuxClient.bearerToken(nil) == nil)
    }

    // c: pairing secrets are never zeros, even if the secure source fails.

    @Test func randomHexFallsBackWhenTheSecureSourceFails() {
        let hex = FleetConnection.randomHex(32, secure: { _ in false })
        #expect(hex.count == 64)
        #expect(hex.allSatisfy { $0.isHexDigit })
        #expect(hex != String(repeating: "0", count: 64))
        #expect(FleetConnection.randomHex(32).count == 64)
    }

    @Test func theRecipeGoesThroughTheClientsSession() async throws {
        ClientStub.status = 404
        var client = DarkmuxClient()
        client.session = ClientStub.session
        let none = try await client.recipe(token: "t", workspace: "site-1")
        #expect(none == nil, "no recipe is nil, never an error")
        #expect(ClientStub.lastURL?.query == "workspace=site-1")
        ClientStub.status = 500
        do {
            _ = try await client.recipe(token: "t", workspace: "site-1")
            Issue.record("expected a refusal")
        } catch let error as DarkmuxClient.ClientError {
            #expect(error.status == 500)
        }
    }
}

/// Answers every darkmux request with one status (this file's suites only).
final class ClientStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastURL: URL?
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClientStub.self]
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"unknown token"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 5: a damaged local-bots.json costs as little as it can. Each test uses
/// its own folder, never `.shared`.
struct ReviewFindingsLocalStateTests {
    private func tempFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-bots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func oneBadEntryCostsOnlyItself() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("local-bots.json")
        let good = UUID(), bad = UUID()
        // The bad entry's workspace name is a number, not a string.
        try Data(#"{"\#(good.uuidString)":{"workspaceName":"site-1","localRuns":["r1"]},"\#(bad.uuidString)":{"workspaceName":7}}"#.utf8).write(to: file)
        let local = LocalBotState(fileURL: file)
        #expect(local[good]?.workspaceName == "site-1")
        #expect(local[good]?.localRuns == ["r1"])
        #expect(local[bad] == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["local-bots.json"], "a readable file stays where it is: \(names)")
    }

    @Test func anUnreadableFileIsMovedAsideNeverOverwritten() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("local-bots.json")
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: file)
        let local = LocalBotState(fileURL: file)
        let id = UUID()
        #expect(local[id] == nil)
        // The next change saves a new file; the damaged one is still there.
        local.update(id) { $0.workspaceName = "site-1" }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names.count == 2, "\(names)")
        let aside = try #require(names.first { $0.hasPrefix("local-bots.json.unreadable-") })
        let kept = try Data(contentsOf: dir.appendingPathComponent(aside))
        #expect(kept == damaged)
        #expect(LocalBotState(fileURL: file)[id]?.workspaceName == "site-1")
    }

    @Test func aMissingFileStartsEmptyAndMovesNothing() throws {
        let dir = try tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = LocalBotState(fileURL: dir.appendingPathComponent("local-bots.json"))
        #expect(local[UUID()] == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.isEmpty)
    }
}

/// 7: failures say what happened, never a technical step to take.
struct ReviewFindingsCopyTests {
    private let steps = ["push that commit", "git push", "checkout's remote", "in the app's settings", "permission, then"]

    @Test func gitHubNotHavingTheBaseAsksForNoPush() {
        let said = GitHubPR.Failure.baseMissing("abc1234def").localizedDescription
        #expect(said.contains("GitHub doesn't have yet"), "\(said)")
        #expect(!said.contains("abc1234"), "the commit's id isn't up front: \(said)")
        for step in steps { #expect(!said.localizedCaseInsensitiveContains(step), "\(said)") }
    }

    @Test func aMissingDefaultBranchAsksForNoGitStep() {
        let said = DarkmuxPlain.sentence(DarkmuxClient.ClientError(message: "no origin default branch", status: 409))
        #expect(said.contains("default branch"), "\(said)")
        #expect(!said.contains("busy"))
        for step in steps { #expect(!said.localizedCaseInsensitiveContains(step), "\(said)") }
    }

    @Test func notBeingAllowedToCreateARepoAsksOnlyWhatYouCanDo() {
        let said = GitHubRepoMaker.Failure.cantCreate.localizedDescription
        #expect(said.contains("approve"), "\(said)")
        #expect(said.contains("Back up to GitHub off"), "\(said)")
        for step in steps { #expect(!said.localizedCaseInsensitiveContains(step), "\(said)") }
    }
}

/// d: deleting a bot leaves nothing of it on this device.
@Suite(.serialized) @MainActor
struct ReviewFindingsDeleteTests {
    @Test func aBotsOwnModelChoicesAreRemovedOnEveryMachine() {
        let settings = ModelSettingsStore(backing: MemoryBacking())
        let gone = UUID(), kept = UUID()
        settings.setBotMode(.ask, bot: gone, machine: "m-studio")
        settings.setBotMode(.model("flint-rec"), bot: gone, machine: "m-laptop")
        settings.setBotMode(.ask, bot: kept, machine: "m-studio")
        settings.save(ModelSettings(mode: .ask), machine: "m-studio")
        settings.removeBotModes(bot: gone)
        #expect(settings.botMode(bot: gone, machine: "m-studio") == nil)
        #expect(settings.botMode(bot: gone, machine: "m-laptop") == nil)
        #expect(settings.botMode(bot: kept, machine: "m-studio") == .ask, "another bot's stay")
        #expect(settings.settings(machine: "m-studio").mode == .ask, "and the app's own")
    }

    @Test func deletingABotRemovesItsBugScreenshotsAndModelChoices() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "")
        let other = store.add(name: "other", instructions: "")
        let card = store.append(.assistant, "{}", kind: .bugCard, to: store.conversation(for: .bot(bot.id)))
        let otherCard = store.append(.assistant, "{}", kind: .bugCard, to: store.conversation(for: .bot(other.id)))
        BugCrops.shared[card.id] = Data([1])
        BugCrops.shared[otherCard.id] = Data([2])
        ModelSettingsStore.shared.setBotMode(.ask, bot: bot.id, machine: "m-findings")
        ModelSettingsStore.shared.setBotMode(.ask, bot: other.id, machine: "m-findings")
        let cardId = card.id, botId = bot.id
        store.delete(bot)
        #expect(BugCrops.shared[cardId] == nil)
        #expect(ModelSettingsStore.shared.botMode(bot: botId, machine: "m-findings") == nil)
        #expect(BugCrops.shared[otherCard.id] == Data([2]), "another bot's stay")
        #expect(ModelSettingsStore.shared.botMode(bot: other.id, machine: "m-findings") == .ask)
        BugCrops.shared[otherCard.id] = nil
        ModelSettingsStore.shared.removeBotModes(bot: other.id)
    }
}

/// The preview: a pick counts only from its own page, and nothing but a
/// clicked link takes it to another site.
struct ReviewFindingsPreviewTests {
    private let home = URL(string: "http://127.0.0.1:5000/")!

    @Test func aPickCountsOnlyFromThePreviewsOwnSite() {
        #expect(PreviewNavigation.isPreviewOrigin(scheme: "http", host: "127.0.0.1", port: 5000, home: home))
        #expect(PreviewNavigation.isPreviewOrigin(scheme: "HTTP", host: "127.0.0.1", port: 5000, home: URL(string: "http://127.0.0.1:5000/about?x=1")!))
        #expect(!PreviewNavigation.isPreviewOrigin(scheme: "http", host: "127.0.0.1", port: 6000, home: home), "another port is another site")
        #expect(!PreviewNavigation.isPreviewOrigin(scheme: "https", host: "127.0.0.1", port: 5000, home: home))
        #expect(!PreviewNavigation.isPreviewOrigin(scheme: "https", host: "evil.example", port: 0, home: home))
        #expect(!PreviewNavigation.isPreviewOrigin(scheme: "http", host: "localhost", port: 5000, home: home), "the host as written, never guessed equal")
        #expect(!PreviewNavigation.isPreviewOrigin(scheme: "http", host: "127.0.0.1", port: 5000, home: nil), "no preview, no pick")
        // An opaque origin (a sandboxed frame, about:blank, a data: page).
        #expect(!PreviewNavigation.isPreviewOrigin(scheme: "", host: "", port: 0, home: home))
        #expect(!PreviewNavigation.isPreviewOrigin(scheme: "about", host: "", port: 0, home: URL(string: "about:blank")!))
    }

    @Test func webKitsPortZeroIsTheSchemesOwn() {
        let site = URL(string: "https://site.tail1234.ts.net/")!
        #expect(PreviewNavigation.isPreviewOrigin(scheme: "https", host: "site.tail1234.ts.net", port: 0, home: site))
        #expect(PreviewNavigation.isPreviewOrigin(scheme: "https", host: "Site.Tail1234.ts.net", port: 443, home: site))
        #expect(PreviewNavigation.isPreviewOrigin(scheme: "http", host: "site.ts.net", port: 0, home: URL(string: "http://site.ts.net:80/")!))
        #expect(!PreviewNavigation.isPreviewOrigin(scheme: "https", host: "site.tail1234.ts.net", port: 8443, home: site))
    }
}
