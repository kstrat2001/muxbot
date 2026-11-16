import Foundation
import Darwin
import OSLog
#if os(iOS)
import UIKit
#endif

/// This app's pairing with darkmux on this Mac, and the real runs it sends.
/// Unpaired, runs can't start.
@MainActor @Observable
final class FleetConnection {
    enum State: Equatable {
        case unpaired
        case waiting(code: String, expires: Date)
        case paired(name: String)
        case failed(String)
    }

    private(set) var state: State = .unpaired
    var client = DarkmuxClient()
    private let keychain: any KeychainProviding
    /// Where the paired name lives: the app's, or the one a test passed
    /// (pairing and unpairing use it too, never the app's by accident).
    @ObservationIgnored private let defaults: UserDefaults
    private static let tokenKey = "darkmux.client.token"
    private static let nameKey = "darkmux.client.name"
    /// A new id for each pairing: runs remember the one they started under.
    static let pairingIdKey = "darkmux.client.pairing"
    var pairingId: String? { defaults.string(forKey: Self.pairingIdKey) }
    /// The Mac's tailnet address, when this device paired over the tailnet
    /// (nil: paired with darkmux on this Mac). Not a secret: the token is.
    static let remoteURLKey = "darkmux.client.remoteURL"
    var remoteURL: URL? { defaults.string(forKey: Self.remoteURLKey).flatMap(RemotePairing.address) }
    /// The pairing going on now is over the tailnet.
    private(set) var pairingRemotely = false
    /// A Mac's address from a link this app was opened with (its QR code),
    /// for the pairing screen to start from.
    var offeredRemoteURL: URL?
    private var pairing: Task<Void, Never>?

    /// `defaults` holds the paired name (tests pass their own, never the
    /// app's).
    init(keychain: any KeychainProviding = KeychainHelper(), defaults: UserDefaults = TestIsolation.defaults) {
        self.keychain = keychain
        self.defaults = defaults
        switch keychain.read(key: Self.tokenKey) {
        case let .value(stored):
            cachedToken = .some(stored)
            if let name = defaults.string(forKey: Self.nameKey) { state = .paired(name: name) }
        case .notFound:
            cachedToken = .some(nil)
        case .unavailable:
            // Locked: still paired if you were; the token is read later.
            if let name = defaults.string(forKey: Self.nameKey) { state = .paired(name: name) }
        }
        restoreBaseURL()
        client.onUnauthorized = { [weak self] refused in Task { @MainActor in self?.revoked(token: refused) } }
    }

    /// The token, read from the Keychain once and kept: views ask for it on
    /// every redraw, and a Keychain read takes milliseconds.
    var token: String? {
        if let cachedToken { return cachedToken }
        switch keychain.read(key: Self.tokenKey) {
        case let .value(read): cachedToken = .some(read); return read
        case .notFound: cachedToken = .some(nil); return nil
        // Locked: nothing remembered, so it's read again next time.
        case .unavailable: return nil
        }
    }
    @ObservationIgnored private var cachedToken: String??

    var isPaired: Bool { if case .paired = state { true } else { false } }

    /// Starts a pairing request and waits for `darkmux client approve`. The
    /// owner chooses which profiles to grant there. `mac`: the Mac's tailnet
    /// address, to pair this device over the tailnet; that always waits for
    /// the operator, who compares the code this app shows (darkmux #3560).
    func pair(over mac: URL? = nil) {
        pairing?.cancel()
        pairingRemotely = mac != nil
        client.baseURL = mac ?? DarkmuxClient.localURL
        let code = Self.makeCode()
        let secret = Self.randomHex(32)
        let device = "\(Self.deviceName) · Mux Bot"
        state = .waiting(code: code, expires: Date().addingTimeInterval(10 * 60))
        pairing = Task {
            do {
                let id = try await client.requestPairing(deviceName: device, code: code, secret: secret)
                var misses = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let status: DarkmuxClient.PairStatus
                    do {
                        status = try await client.pairStatus(requestId: id, secret: secret)
                        misses = 0
                    } catch let error as URLError where error.code != .cancelled && misses < Self.pairStatusMisses {
                        // One slow answer while you approve on the Mac isn't
                        // a failed pairing: ask again; only several in a row count.
                        misses += 1
                        continue
                    } catch let error as DarkmuxClient.ClientError where RemotePairing.isTransient(error.code) && misses < Self.pairStatusMisses {
                        // Tailscale on the Mac couldn't say who's asking yet.
                        misses += 1
                        continue
                    }
                    switch status.status {
                    case "approved":
                        guard let token = status.token, let name = status.clientName else { throw DarkmuxClient.ClientError(message: "darkmux approved without a token") }
                        defaults.set(name, forKey: Self.nameKey)
                        if let mac { defaults.set(mac.absoluteString, forKey: Self.remoteURLKey) } else { defaults.removeObject(forKey: Self.remoteURLKey) }
                        completePairing(token: token, name: name)
                        return
                    case "denied": state = .failed("The request was denied."); return
                    case "expired": state = .failed("The request expired. Try again."); return
                    default: continue
                    }
                }
            } catch is CancellationError {
            } catch {
                failureDetails = DarkmuxPlain.details(error)
                state = .failed(Self.plainError(error, remote: mac != nil))
                restoreBaseURL()
            }
        }
    }

    /// How many unanswered checks in a row a waiting pairing rides out.
    static let pairStatusMisses = 3

    /// Called when pairing completes (the app starts what waited for it).
    var onPaired: (() -> Void)?

    /// Keeps the token and tells the app it's paired.
    func completePairing(token: String, name: String) {
        defaults.set(UUID().uuidString, forKey: Self.pairingIdKey)
        // Not kept: the pairing still works until the app quits, and the
        // log says why it will ask again after that.
        if !keychain.save(key: Self.tokenKey, value: token) { Self.log.error("The pairing token couldn't be saved to the Keychain") }
        cachedToken = .some(token)
        state = .paired(name: name)
        restoreBaseURL()
        onPaired?()
    }

    /// What the pairing screen says when darkmux forgot this app.
    /// The name darkmux gave this app's pairing.
    /// What darkmux said when pairing failed, for Show details.
    var failureDetails: String?
    var pairedName: String? { if case let .paired(name) = state { name } else { nil } }

    static let revokedMessage = String(localized: "darkmux no longer knows this app. Pair again.")
    /// Shows pairing (set by the app).
    var onRevoked: (() -> Void)?

    /// darkmux answered 401 to `refused`: when that's this app's token now,
    /// the pairing was revoked there. Forget the token, say so plainly, and
    /// show pairing. A late answer about an earlier pairing's token changes
    /// nothing: the app has paired again since.
    func revoked(token refused: String) {
        guard let token, token == refused else { return }
        unpair()
        state = .failed(Self.revokedMessage)
        onRevoked?()
    }

    func cancelPairing() {
        pairing?.cancel()
        state = .unpaired
        restoreBaseURL()
    }

    func unpair() {
        keychain.delete(key: Self.tokenKey)
        cachedToken = .some(nil)
        defaults.removeObject(forKey: Self.nameKey)
        defaults.removeObject(forKey: Self.remoteURLKey)
        state = .unpaired
        restoreBaseURL()
    }

    /// Requests go where this device's pairing is: the Mac's tailnet
    /// address when it paired over the tailnet, else this Mac.
    private func restoreBaseURL() {
        client.baseURL = (token != nil ? remoteURL : nil) ?? DarkmuxClient.localURL
        pairingRemotely = false
    }

    /// Paired over the tailnet: requests go to the Mac's tailnet address.
    var isRemote: Bool { isPaired && remoteURL != nil }

    /// A pairing failure in plain words. The endpoint not answering is the
    /// usual one; the pairing screen links darkmux's guide (never a command).
    static func plainError(_ error: any Error, remote: Bool = false) -> String {
        if let url = error as? URLError,
           [.cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost, .notConnectedToInternet].contains(url.code) {
            return remote
                ? String(localized: "Your Mac didn't answer over your tailnet. Make sure this device and your Mac are both connected to Tailscale and darkmux is running on the Mac, then try again.")
                : String(localized: "darkmux isn't running on this Mac. darkmux's guide shows how to start it; then try again.")
        }
        // darkmux's own words go behind Show details (`failureDetails`).
        if let client = error as? DarkmuxClient.ClientError {
            if let sentence = RemotePairing.sentence(client.code) { return sentence }
            if remote, client.code == "unavailable" {
                return String(localized: "Your Mac can't check who's asking right now. Try again in a moment.")
            }
            if client.status == 429 {
                return remote
                    ? String(localized: "This device already has two pairing requests waiting on your Mac. Wait for one to end, then try again.")
                    : String(localized: "Pairing didn't work: darkmux has too many pairing requests waiting. Try again in a moment.")
            }
        }
        return "Pairing didn't work: \(DarkmuxPlain.sentence(error))"
    }

    /// The real home folder (a sandboxed app's NSHomeDirectory is its container).
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// This device's name, as a pairing request names it.
    static var deviceName: String {
        #if os(macOS)
        ProcessInfo.processInfo.hostName
        #else
        UIDevice.current.name
        #endif
    }

    /// This Mac's name, for "ready on MacBook Pro".
    static var machineName: String {
        #if os(macOS)
        Host.current().localizedName ?? "this Mac"
        #else
        "this device"
        #endif
    }

    private static func makeCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let pick = { String((0..<3).map { _ in alphabet.randomElement()! }) }
        return "\(pick())-\(pick())"
    }

    private static let log = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "pairing")

    /// Random bytes as hex. If the system's secure source fails, the
    /// standard library's generator (also cryptographically secure on
    /// Apple platforms) fills them: never zeros.
    static func randomHex(_ bytes: Int, secure: (inout [UInt8]) -> Bool = FleetConnection.secureRandom) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        if !secure(&raw) {
            log.error("SecRandomCopyBytes failed; using the system random number generator")
            var generator = SystemRandomNumberGenerator()
            raw = (0..<bytes).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
        }
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func secureRandom(_ buffer: inout [UInt8]) -> Bool {
        let count = buffer.count
        return SecRandomCopyBytes(kSecRandomDefault, count, &buffer) == errSecSuccess
    }
}
