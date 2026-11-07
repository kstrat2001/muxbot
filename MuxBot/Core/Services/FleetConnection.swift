import Foundation
import Darwin

/// This app's pairing with darkmux on this Mac, and the real runs it sends.
/// Unpaired, runs stay simulated.
@MainActor @Observable
final class FleetConnection {
    enum State: Equatable {
        case unpaired
        case waiting(code: String)
        case paired(name: String, profiles: [String])
        case failed(String)
    }

    private(set) var state: State = .unpaired
    var client = DarkmuxClient()
    private let keychain = KeychainHelper()
    private static let tokenKey = "darkmux.client.token"
    private static let nameKey = "darkmux.client.name"
    private static let profilesKey = "darkmux.client.profiles"
    private var pairing: Task<Void, Never>?

    init() {
        if keychain.get(key: Self.tokenKey) != nil, let name = UserDefaults.standard.string(forKey: Self.nameKey) {
            state = .paired(name: name, profiles: UserDefaults.standard.stringArray(forKey: Self.profilesKey) ?? [])
        }
    }

    var token: String? { keychain.get(key: Self.tokenKey) }
    var profile: String? { if case let .paired(_, profiles) = state { profiles.first } else { nil } }
    var isPaired: Bool { if case .paired = state { true } else { false } }

    /// Starts a pairing request and waits for `darkmux client approve`.
    func pair(profile: String) {
        pairing?.cancel()
        let code = Self.makeCode()
        let secret = Self.randomHex(32)
        let device = "\(ProcessInfo.processInfo.hostName) · Mux Bot"
        state = .waiting(code: code)
        pairing = Task {
            do {
                let scopes = DarkmuxClient.Scopes(profiles: [profile], workspace: true)
                let id = try await client.requestPairing(deviceName: device, code: code, secret: secret, scopes: scopes)
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    let status = try await client.pairStatus(requestId: id, secret: secret)
                    switch status.status {
                    case "approved":
                        guard let token = status.token, let name = status.clientName else { throw DarkmuxClient.ClientError(message: "darkmux approved without a token") }
                        keychain.save(key: Self.tokenKey, value: token)
                        let profiles = status.scopes?.profiles ?? [profile]
                        UserDefaults.standard.set(name, forKey: Self.nameKey)
                        UserDefaults.standard.set(profiles, forKey: Self.profilesKey)
                        state = .paired(name: name, profiles: profiles)
                        return
                    case "denied": state = .failed("The request was denied."); return
                    case "expired": state = .failed("The request expired. Try again."); return
                    default: continue
                    }
                }
            } catch is CancellationError {
            } catch {
                state = .failed("\(error.localizedDescription) Is `darkmux client serve` running?")
            }
        }
    }

    func cancelPairing() {
        pairing?.cancel()
        state = .unpaired
    }

    func unpair() {
        keychain.delete(key: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        UserDefaults.standard.removeObject(forKey: Self.profilesKey)
        state = .unpaired
    }

    /// The real home folder (a sandboxed app's NSHomeDirectory is its container).
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// A bot's folder resource that darkmux may work in (under ~/.darkmux/worktrees).
    static func workdir(for bot: Bot) -> String? {
        let folders = bot.sortedResources.filter { $0.kind == .folder }.map(\.value)
        guard let path = folders.first(where: { $0.contains("/.darkmux/worktrees/") }) else { return nil }
        return path.hasPrefix("~/") ? realHome + path.dropFirst(1) : path
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
