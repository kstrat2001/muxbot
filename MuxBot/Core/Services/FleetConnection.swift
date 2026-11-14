import Foundation
import Darwin
import OSLog

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
    private var pairing: Task<Void, Never>?

    /// `defaults` holds the paired name (tests pass their own, never the
    /// app's).
    init(keychain: any KeychainProviding = KeychainHelper(), defaults: UserDefaults = TestIsolation.defaults) {
        self.keychain = keychain
        self.defaults = defaults
        let stored = keychain.get(key: Self.tokenKey)
        cachedToken = .some(stored)
        if stored != nil, let name = defaults.string(forKey: Self.nameKey) {
            state = .paired(name: name)
        }
        client.onUnauthorized = { [weak self] refused in Task { @MainActor in self?.revoked(token: refused) } }
    }

    /// The token, read from the Keychain once and kept: views ask for it on
    /// every redraw, and a Keychain read takes milliseconds.
    var token: String? {
        if let cachedToken { return cachedToken }
        let read = keychain.get(key: Self.tokenKey)
        cachedToken = .some(read)
        return read
    }
    @ObservationIgnored private var cachedToken: String??

    var isPaired: Bool { if case .paired = state { true } else { false } }

    /// Starts a pairing request and waits for `darkmux client approve`. The
    /// owner chooses which profiles to grant there.
    func pair() {
        pairing?.cancel()
        let code = Self.makeCode()
        let secret = Self.randomHex(32)
        let device = "\(ProcessInfo.processInfo.hostName) · Mux Bot"
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
                    }
                    switch status.status {
                    case "approved":
                        guard let token = status.token, let name = status.clientName else { throw DarkmuxClient.ClientError(message: "darkmux approved without a token") }
                        defaults.set(name, forKey: Self.nameKey)
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
                state = .failed(Self.plainError(error))
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
    }

    func unpair() {
        keychain.delete(key: Self.tokenKey)
        cachedToken = .some(nil)
        defaults.removeObject(forKey: Self.nameKey)
        state = .unpaired
    }

    /// A pairing failure in plain words. The endpoint not answering is the
    /// usual one; the pairing screen links darkmux's guide (never a command).
    static func plainError(_ error: any Error) -> String {
        if let url = error as? URLError,
           [.cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost].contains(url.code) {
            return String(localized: "darkmux isn't running on this Mac. darkmux's guide shows how to start it; then try again.")
        }
        // darkmux's own words go behind Show details (`failureDetails`).
        if let client = error as? DarkmuxClient.ClientError, client.status == 429 {
            return String(localized: "Pairing didn't work: darkmux has too many pairing requests waiting. Try again in a moment.")
        }
        return "Pairing didn't work: \(DarkmuxPlain.sentence(error))"
    }

    /// The real home folder (a sandboxed app's NSHomeDirectory is its container).
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
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
