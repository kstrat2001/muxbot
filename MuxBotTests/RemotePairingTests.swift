import Foundation
import Testing
@testable import MuxBot

/// Pairing over the tailnet (darkmux #3560), built against darkmux's client
/// OpenAPI document: whoami's `remote` and `via`, the capability gate, the
/// Mac's address and QR link, and the tailnet refusals in plain words.
@Suite(.serialized) @MainActor
struct RemotePairingTests {
    private func whoami(_ json: String) throws -> DarkmuxClient.Whoami {
        try JSONDecoder().decode(DarkmuxClient.Whoami.self, from: Data(json.utf8))
    }

    @Test func whoamiReadsRemoteAndVia() throws {
        let w = try whoami(#"{"client_name":"m","scopes":{},"machine":{},"version":"5.12.0","capabilities":["remote_tailscale","remote_requests"],"remote":{"state":"available","url":"https://mac.tail1234.ts.net","reason":null},"via":"tailnet"}"#)
        #expect(w.can("remote_requests"))
        #expect(w.overTailnet)
        #expect(RemoteAccess.of(w) == .available(URL(string: "https://mac.tail1234.ts.net")!))
    }

    @Test func anOlderDarkmuxShowsNothing() throws {
        let w = try whoami(#"{"client_name":"m","scopes":{"profiles":null}}"#)
        #expect(w.capabilities == nil && w.remote == nil && w.via == nil)
        #expect(RemoteAccess.of(w) == .notSupported)
    }

    @Test func eachRemoteStateIsGatedOnCapabilities() throws {
        let off = try whoami(#"{"scopes":{},"capabilities":["remote_tailscale"],"remote":{"state":"off"}}"#)
        #expect(RemoteAccess.of(off) == .off)
        let down = try whoami(#"{"scopes":{},"capabilities":["remote_tailscale","remote_requests"],"remote":{"state":"unavailable","reason":"tailscale is not logged in"}}"#)
        #expect(RemoteAccess.of(down) == .unavailable(reason: "tailscale is not logged in"))
        let noPairing = try whoami(#"{"scopes":{},"capabilities":["remote_tailscale"],"remote":{"state":"available","url":"https://mac.tail1234.ts.net"}}"#)
        #expect(RemoteAccess.of(noPairing) == .needsNewerDarkmux)
        let ungated = try whoami(#"{"scopes":{},"capabilities":[],"remote":{"state":"available","url":"https://mac.tail1234.ts.net"}}"#)
        #expect(RemoteAccess.of(ungated) == .notSupported)
    }

    @Test func onlyAnHTTPSTailnetAddressIsAMac() {
        #expect(RemotePairing.address("https://mac.tail1234.ts.net/") == URL(string: "https://mac.tail1234.ts.net"))
        #expect(RemotePairing.address(" https://MAC.tail1234.ts.net ")?.host == "mac.tail1234.ts.net")
        #expect(RemotePairing.address("http://mac.tail1234.ts.net") == nil)
        #expect(RemotePairing.address("https://evil.example.com") == nil)
        #expect(RemotePairing.address("https://ts.net.evil.com") == nil)
        #expect(RemotePairing.address("https://user:pw@mac.tail1234.ts.net") == nil)
        #expect(RemotePairing.address("not a url") == nil)
    }

    @Test func theQRLinkRoundTrips() {
        let mac = URL(string: "https://mac.tail1234.ts.net")!
        let link = RemotePairing.link(for: mac)
        #expect(link.scheme == "muxbot")
        #expect(RemotePairing.mac(from: link.absoluteString) == mac)
        #expect(RemotePairing.mac(from: "muxbot://pair?url=https%3A%2F%2Fevil.example.com") == nil)
        #expect(RemotePairing.mac(from: "muxbot://other?url=https%3A%2F%2Fmac.tail1234.ts.net") == nil)
        #expect(RemotePairing.qrCode(link.absoluteString) != nil)
    }

    @Test(arguments: ["not_forwarded", "not_paired_remotely", "remote_user_not_owner", "remote_identity_missing",
                      "remote_identity_mismatch", "remote_identity_unconfirmed", "remote_device_unknown", "remote_device_mismatch"])
    func everyTailnetRefusalHasItsOwnPlainSentence(code: String) {
        let error = DarkmuxClient.ClientError(message: "raw words for a person", status: 403, code: code)
        let sentence = DarkmuxPlain.sentence(error)
        #expect(sentence == RemotePairing.sentence(code))
        #expect(!sentence.contains("raw words"), "darkmux's own words go behind Show details")
        #expect(!sentence.contains(code))
        #expect(FleetConnection.plainError(error, remote: true) == sentence)
        #expect(DarkmuxPlain.saysWhy(error))
    }

    @Test func remotePairingFailuresAreWordedForTheTailnet() {
        #expect(FleetConnection.plainError(URLError(.cannotConnectToHost), remote: true).contains("tailnet"))
        let busy = DarkmuxClient.ClientError(message: "x", status: 429, code: "too_many_requests")
        #expect(FleetConnection.plainError(busy, remote: true).contains("two pairing requests"))
        let notNow = DarkmuxClient.ClientError(message: "x", status: 503, code: "unavailable")
        #expect(FleetConnection.plainError(notNow, remote: true) == "Your Mac can't check who's asking right now. Try again in a moment.")
        #expect(RemotePairing.isTransient("unavailable") && RemotePairing.isTransient("remote_device_unknown"))
        #expect(!RemotePairing.isTransient("remote_device_mismatch"))
    }

    @Test func aTailnetPairingSendsToTheMacAndUnpairingComesHome() {
        let defaults = UserDefaults(suiteName: "muxbot-tests-remote-\(UUID().uuidString)")!
        let connection = FleetConnection(keychain: MemoryKeychain(), defaults: defaults)
        #expect(connection.client.baseURL == DarkmuxClient.localURL)
        let mac = URL(string: "https://mac.tail1234.ts.net")!
        defaults.set(mac.absoluteString, forKey: FleetConnection.remoteURLKey)
        connection.completePairing(token: "t0ken", name: "phone")
        #expect(connection.isRemote)
        #expect(connection.client.baseURL == mac)
        connection.unpair()
        #expect(!connection.isRemote)
        #expect(connection.client.baseURL == DarkmuxClient.localURL)
        #expect(defaults.string(forKey: FleetConnection.remoteURLKey) == nil)
    }

    @Test func aKeptTailnetPairingStillGoesToTheMacAfterARelaunch() {
        let defaults = UserDefaults(suiteName: "muxbot-tests-remote-\(UUID().uuidString)")!
        defaults.set("https://mac.tail1234.ts.net", forKey: FleetConnection.remoteURLKey)
        defaults.set("phone", forKey: "darkmux.client.name")
        let keychain = MemoryKeychain()
        keychain.items["darkmux.client.token"] = "t0ken"
        let connection = FleetConnection(keychain: keychain, defaults: defaults)
        #expect(connection.client.baseURL == URL(string: "https://mac.tail1234.ts.net"))
    }

    @Test func theTailnetStatusLine() {
        #expect(ComputerStatus.of(paired: true, answers: true, overTailnet: true) == .tailnet(online: true))
        #expect(ComputerStatus.tailnet(online: true).isOnline)
        #expect(ComputerStatus.tailnet(online: true).line == "Over your tailnet · Online now")
        #expect(!ComputerStatus.tailnet(online: false).isOnline)
    }
}
