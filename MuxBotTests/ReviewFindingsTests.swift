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
