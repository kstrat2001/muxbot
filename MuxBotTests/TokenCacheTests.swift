import Foundation
import Testing
@testable import MuxBot

/// Views ask for the tokens on every redraw (the thread toolbar's Open PR
/// check, for one). A Keychain read takes milliseconds, so redrawing while
/// the sidebar animates was slow: each token is read from the Keychain
/// once, then kept in memory and updated when it changes.
final class CountingKeychain: KeychainProviding, @unchecked Sendable {
    var items: [String: String] = [:]
    var reads = 0
    func save(key: String, value: String) -> Bool { items[key] = value; return true }
    func get(key: String) -> String? { reads += 1; return items[key] }
    func delete(key: String) { items[key] = nil }
    func deleteAll() { items = [:] }
}

@Suite(.serialized) @MainActor
struct TokenCacheTests {
    @Test func theGitHubTokenIsReadFromTheKeychainOnce() {
        let keychain = CountingKeychain()
        keychain.items[GitHubAuth.tokenKey] = "gho_test"
        let auth = GitHubAuth(clientID: "Iv23test", keychain: keychain)
        for _ in 0..<100 { _ = auth.token }
        #expect(auth.token == "gho_test")
        #expect(keychain.reads == 1)
    }

    @Test func theDarkmuxTokenIsReadFromTheKeychainOnce() {
        let keychain = CountingKeychain()
        keychain.items["darkmux.client.token"] = "abc"
        let connection = FleetConnection(keychain: keychain)
        for _ in 0..<100 { _ = connection.token }
        #expect(connection.token == "abc")
        #expect(keychain.reads == 1)
    }
}
