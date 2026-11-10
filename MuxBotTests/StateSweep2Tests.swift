import Foundation
import Testing
@testable import MuxBot

/// Sweep 2, state: tests run inside the app (its bundle id and container),
/// so nothing they do may reach the real app's pairing, sign-in or files.
@Suite(.serialized) @MainActor
struct TestIsolationTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "muxbot-tests-isolation-\(UUID().uuidString)")! }

    @Test func unpairingUsesTheDefaultsItWasGiven() {
        let defaults = suite()
        defaults.set("Mux Bot test", forKey: "darkmux.client.name")
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let before = UserDefaults.standard.string(forKey: "darkmux.client.name")
        let connection = FleetConnection(keychain: keychain, defaults: defaults)
        #expect(connection.isPaired)
        connection.revoked(token: "t0ken")
        #expect(defaults.string(forKey: "darkmux.client.name") == nil, "the given defaults lose the name")
        #expect(UserDefaults.standard.string(forKey: "darkmux.client.name") == before, "the app's own are untouched")
    }

    @Test func signingOutUsesTheDefaultsItWasGiven() async {
        GitHubStub.reset()
        GitHubStub.on("GET /user", 200, #"{"login":"kain-test"}"#)
        let defaults = suite()
        let keychain = MemoryKeychain()
        keychain.items[GitHubAuth.tokenKey] = "ghu"
        let before = UserDefaults.standard.string(forKey: "github.user.login")
        let auth = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, defaults: defaults, sleep: { _ in })
        await auth.loadUser()
        #expect(defaults.string(forKey: "github.user.login") == "kain-test")
        auth.signOut()
        #expect(defaults.string(forKey: "github.user.login") == nil)
        #expect(UserDefaults.standard.string(forKey: "github.user.login") == before, "the app's own are untouched")
    }

    @Test func byDefaultATestNeverReachesTheAppsDefaultsOrKeychain() {
        #expect(TestIsolation.isTesting)
        #expect(TestIsolation.defaults !== UserDefaults.standard)
        #expect(KeychainHelper.defaultService != "com.darklyenergized.darkmuxapp")
    }
}
