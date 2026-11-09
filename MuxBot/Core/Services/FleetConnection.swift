import Foundation
import Darwin

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
    private static let tokenKey = "darkmux.client.token"
    private static let nameKey = "darkmux.client.name"
    private var pairing: Task<Void, Never>?

    /// `defaults` holds the paired name (tests pass their own, never the
    /// app's).
    init(keychain: any KeychainProviding = KeychainHelper(), defaults: UserDefaults = .standard) {
        self.keychain = keychain
        let stored = keychain.get(key: Self.tokenKey)
        cachedToken = .some(stored)
        if stored != nil, let name = defaults.string(forKey: Self.nameKey) {
            state = .paired(name: name)
        }
        client.onUnauthorized = { [weak self] in Task { @MainActor in self?.revoked() } }
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

    /// How to run darkmux on this Mac, for the commands we show: `darkmux`
    /// on PATH, or a dev build named by MUXBOT_DARKMUX_CLI in the gitignored
    /// Config/Local.xcconfig.
    var cliCommand: String {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "MuxBotDarkmuxCLI") as? String)?
            .trimmingCharacters(in: .whitespaces)
        return configured.flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 } ?? "darkmux"
    }
    var approveCommand: String { "\(cliCommand) client approve" }
    var serveCommand: String { "\(cliCommand) client serve" }
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
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let status = try await client.pairStatus(requestId: id, secret: secret)
                    switch status.status {
                    case "approved":
                        guard let token = status.token, let name = status.clientName else { throw DarkmuxClient.ClientError(message: "darkmux approved without a token") }
                        UserDefaults.standard.set(name, forKey: Self.nameKey)
                        completePairing(token: token, name: name)
                        return
                    case "denied": state = .failed("The request was denied."); return
                    case "expired": state = .failed("The request expired. Try again."); return
                    default: continue
                    }
                }
            } catch is CancellationError {
            } catch {
                state = .failed(Self.plainError(error))
            }
        }
    }

    /// Called when pairing completes (the app starts what waited for it).
    var onPaired: (() -> Void)?

    /// Keeps the token and tells the app it's paired.
    func completePairing(token: String, name: String) {
        keychain.save(key: Self.tokenKey, value: token)
        cachedToken = .some(token)
        state = .paired(name: name)
        onPaired?()
    }

    /// What the pairing screen says when darkmux forgot this app.
    static let revokedMessage = String(localized: "darkmux no longer knows this app. Pair again.")
    /// Shows pairing (set by the app).
    var onRevoked: (() -> Void)?

    /// darkmux answered 401 with this app's token: the pairing was revoked
    /// there. Forget the token, say so plainly, and show pairing.
    func revoked() {
        guard token != nil else { return }
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
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        state = .unpaired
    }

    /// A pairing failure in plain words. The endpoint not answering is the
    /// usual one; the pairing screen shows the command to start it.
    static func plainError(_ error: any Error) -> String {
        if let url = error as? URLError,
           [.cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost].contains(url.code) {
            return "darkmux isn't answering on this Mac. Start it in Terminal with the command below, then try again."
        }
        return "Pairing didn't work: \(error.localizedDescription)"
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

    private static func randomHex(_ bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        return raw.map { String(format: "%02x", $0) }.joined()
    }
}
