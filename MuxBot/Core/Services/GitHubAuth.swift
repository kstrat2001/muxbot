import Foundation

/// Sign in with GitHub through the device flow (no client secret): you get
/// a short code, approve it at github.com/login/device, and the token stays
/// in this device's Keychain. With it, GitHub reads see private repos and
/// get 5,000 requests an hour, and the app can open PRs.
@MainActor @Observable
final class GitHubAuth {
    enum State: Equatable {
        case signedOut
        case waiting(userCode: String, url: URL)
        case signedIn(login: String)
        case failed(String)
    }

    enum InstallState: Equatable {
        case installed
        /// The Mux Bot GitHub App isn't installed on that repo: install it here.
        case notInstalled(URL)
        case unknown(String)
    }

    nonisolated static let tokenKey = "github.user.token"
    private static let loginKey = "github.user.login"

    private(set) var state: State = .signedOut
    let clientID: String?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let keychain: any KeychainProviding
    @ObservationIgnored private let sleep: @Sendable (Double) async throws -> Void
    @ObservationIgnored private var flow: Task<Void, Never>?

    init(clientID: String? = Bundle.main.object(forInfoDictionaryKey: "MuxBotGitHubClientID") as? String,
         session: URLSession = .shared,
         keychain: any KeychainProviding = KeychainHelper(),
         sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.clientID = clientID
        self.session = session
        self.keychain = keychain
        self.sleep = sleep
        if keychain.get(key: Self.tokenKey) != nil {
            state = .signedIn(login: UserDefaults.standard.string(forKey: Self.loginKey) ?? "GitHub")
        }
    }

    /// A real client ID came through the build (forks set their own in
    /// Config/Local.xcconfig).
    var isConfigured: Bool { clientID.map { !$0.isEmpty && !$0.hasPrefix("$(") } ?? false }

    var token: String? { keychain.get(key: Self.tokenKey) }

    /// Starts the device flow and waits for your approval. `showCode` gets
    /// the code to type and where (the UI also opens the page).
    func signIn(showCode: @escaping (String, URL) -> Void = { _, _ in }) async {
        guard isConfigured, let clientID else { state = .failed("This build has no GitHub client ID."); return }
        do {
            struct Code: Decodable { var device_code: String; var user_code: String; var verification_uri: String; var expires_in: Int; var interval: Int? }
            let code: Code = try await post("https://github.com/login/device/code", ["client_id": clientID])
            let url = URL(string: code.verification_uri) ?? URL(string: "https://github.com/login/device")!
            state = .waiting(userCode: code.user_code, url: url)
            showCode(code.user_code, url)
            var interval = Double(code.interval ?? 5)
            let deadline = Date().addingTimeInterval(Double(code.expires_in))
            struct Poll: Decodable { var access_token: String?; var error: String?; var interval: Int? }
            while Date() < deadline {
                try await sleep(interval)
                if Task.isCancelled { return }
                let p: Poll = try await post("https://github.com/login/oauth/access_token", [
                    "client_id": clientID, "device_code": code.device_code,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
                if let token = p.access_token {
                    _ = keychain.save(key: Self.tokenKey, value: token)
                    await loadUser()
                    return
                }
                switch p.error {
                case "authorization_pending": continue
                case "slow_down": interval = Double(p.interval ?? Int(interval) + 5)
                case "access_denied": state = .failed("You declined the sign-in on GitHub."); return
                case "expired_token": state = .failed("The code expired before it was approved. Try again."); return
                case let other?: state = .failed("GitHub sign-in failed: \(other.replacingOccurrences(of: "_", with: " "))."); return
                case nil: continue
                }
            }
            state = .failed("The code expired before it was approved. Try again.")
        } catch {
            state = .failed("GitHub sign-in failed: \(error.localizedDescription)")
        }
    }

    /// Who's signed in (for Settings).
    func loadUser() async {
        struct User: Decodable { var login: String }
        guard let token else { state = .signedOut; return }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
           let user = try? JSONDecoder().decode(User.self, from: data) {
            UserDefaults.standard.set(user.login, forKey: Self.loginKey)
            state = .signedIn(login: user.login)
        } else {
            state = .signedIn(login: UserDefaults.standard.string(forKey: Self.loginKey) ?? "GitHub")
        }
    }

    func signOut() {
        flow?.cancel()
        keychain.delete(key: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.loginKey)
        state = .signedOut
    }

    /// Whether the Mux Bot GitHub App can reach `repo` ("owner/name").
    func installState(for repo: String) async -> InstallState {
        guard let token else { return .unknown("Sign in with GitHub first.") }
        struct Installs: Decodable { struct I: Decodable { var id: Int; var app_slug: String }; var installations: [I] }
        struct Repos: Decodable { struct R: Decodable { var full_name: String }; var repositories: [R] }
        do {
            let installs: Installs = try await get("https://api.github.com/user/installations", token: token)
            for i in installs.installations {
                let repos: Repos = try await get("https://api.github.com/user/installations/\(i.id)/repositories?per_page=100", token: token)
                if repos.repositories.contains(where: { $0.full_name.caseInsensitiveCompare(repo) == .orderedSame }) { return .installed }
            }
            let slug = installs.installations.first?.app_slug
                ?? (Bundle.main.object(forInfoDictionaryKey: "MuxBotGitHubAppSlug") as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
            return .notInstalled(URL(string: slug.map { "https://github.com/apps/\($0)/installations/new" } ?? "https://github.com/settings/installations")!)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    private func post<T: Decodable>(_ url: String, _ form: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parts = URLComponents()
        parts.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((parts.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GitHubError(status: (response as? HTTPURLResponse)?.statusCode ?? 0) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ url: String, token: String) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GitHubError(status: (response as? HTTPURLResponse)?.statusCode ?? 0) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
