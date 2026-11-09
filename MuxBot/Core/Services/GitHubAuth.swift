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
    /// Pages of 100 read per list when checking an install (1,000 entries):
    /// past that it says it couldn't tell rather than "not installed".
    static let installPageCap = 10
    private static let loginKey = "github.user.login"

    private(set) var state: State = .signedOut
    /// What GitHub said when sign-in failed, for "Show details" (the state's
    /// message is the plain sentence).
    private(set) var failureDetails: String?
    let clientID: String?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let keychain: any KeychainProviding
    @ObservationIgnored private let sleep: @Sendable (Double) async throws -> Void

    init(clientID: String? = Bundle.main.object(forInfoDictionaryKey: "MuxBotGitHubClientID") as? String,
         session: URLSession = .shared,
         keychain: any KeychainProviding = KeychainHelper(),
         sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.clientID = clientID
        self.session = session
        self.keychain = keychain
        self.sleep = sleep
        let stored = keychain.get(key: Self.tokenKey)
        cachedToken = .some(stored)
        if stored != nil {
            state = .signedIn(login: UserDefaults.standard.string(forKey: Self.loginKey) ?? "GitHub")
        }
    }

    /// A real client ID came through the build (forks set their own in
    /// Config/Local.xcconfig).
    var isConfigured: Bool { clientID.map { !$0.isEmpty && !$0.hasPrefix("$(") } ?? false }

    /// The token, read from the Keychain once and kept: views ask for it on
    /// every redraw, and a Keychain read takes milliseconds.
    var token: String? {
        if let cachedToken { return cachedToken }
        let read = keychain.get(key: Self.tokenKey)
        cachedToken = .some(read)
        return read
    }
    @ObservationIgnored private var cachedToken: String??

    /// Starts the device flow and waits for your approval. `showCode` gets
    /// the code to type and where (the UI also opens the page).
    func signIn(showCode: @escaping (String, URL) -> Void = { _, _ in }) async {
        guard isConfigured, let clientID else { state = .failed("This build has no GitHub client ID."); return }
        failureDetails = nil
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
                if Task.isCancelled { return canceled() }
                let p: Poll = try await post("https://github.com/login/oauth/access_token", [
                    "client_id": clientID, "device_code": code.device_code,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
                // Cancel can land while the token is on its way: it's dropped.
                if Task.isCancelled { return canceled() }
                if let token = p.access_token {
                    _ = keychain.save(key: Self.tokenKey, value: token)
                    cachedToken = .some(token)
                    await loadUser()
                    return
                }
                switch p.error {
                case "authorization_pending": continue
                case "slow_down": interval = Double(p.interval ?? Int(interval) + 5)
                case "access_denied": state = .failed("You declined the sign-in on GitHub."); return
                case "expired_token": state = .failed("The code expired before it was approved. Try again."); return
                case let other?:
                    failureDetails = "GitHub: \(other)"
                    state = .failed(String(localized: "GitHub sign-in didn't work. Try again in a moment.")); return
                case nil: continue
                }
            }
            state = .failed("The code expired before it was approved. Try again.")
        } catch {
            // A canceled wait or request throws; that's Cancel, not a failure.
            if Task.isCancelled { return canceled() }
            if let refused = error as? SignInRefusal {
                failureDetails = refused.details
                state = .failed(refused.message)
            } else {
                failureDetails = error.localizedDescription
                state = .failed(String(localized: "GitHub sign-in didn't work. Try again in a moment."))
            }
        }
    }

    /// A canceled sign-in leaves you signed out, with no token saved.
    private func canceled() {
        if case .waiting = state { state = .signedOut }
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

    /// To stop a sign-in that's waiting, cancel the task running `signIn`
    /// (the waiting screen's Cancel does, then signs out).
    func signOut() {
        keychain.delete(key: Self.tokenKey)
        cachedToken = .some(nil)
        UserDefaults.standard.removeObject(forKey: Self.loginKey)
        state = .signedOut
    }

    /// Whether the Mux Bot GitHub App can reach `repo` ("owner/name").
    func installState(for repo: String) async -> InstallState {
        guard let token else { return .unknown("Sign in with GitHub first.") }
        struct Installs: Decodable { struct I: Decodable { var id: Int; var app_slug: String }; var installations: [I] }
        struct Repos: Decodable { struct R: Decodable { var full_name: String }; var repositories: [R] }
        do {
            // Both lists are paged (GitHub's Link header, rel="next").
            var installations: [Installs.I] = []
            var truncated = false
            var next: String? = "https://api.github.com/user/installations?per_page=100"
            for _ in 0..<Self.installPageCap {
                guard let url = next else { break }
                let page: (Installs, String?) = try await getPage(url, token: token)
                installations += page.0.installations
                next = page.1
            }
            if next != nil { truncated = true }
            for i in installations {
                var next: String? = "https://api.github.com/user/installations/\(i.id)/repositories?per_page=100"
                for _ in 0..<Self.installPageCap {
                    guard let url = next else { break }
                    let page: (Repos, String?) = try await getPage(url, token: token)
                    if page.0.repositories.contains(where: { $0.full_name.caseInsensitiveCompare(repo) == .orderedSame }) { return .installed }
                    next = page.1
                }
                if next != nil { truncated = true }
            }
            if truncated { return .unknown("You have more GitHub App installations or repos than Mux Bot can check.") }
            let slug = installations.first?.app_slug
                ?? (Bundle.main.object(forInfoDictionaryKey: "MuxBotGitHubAppSlug") as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
            return .notInstalled(URL(string: slug.map { "https://github.com/apps/\($0)/installations/new" } ?? "https://github.com/settings/installations")!)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// Pages of 100 read for your repo list (1,000 repos).
    static let repoPageCap = 10

    /// The repos you own, collaborate on or reach through an organization,
    /// most recently pushed first, paged; `truncated` past the page cap.
    func myRepos() async throws -> (repos: [GitHubRepoSummary], truncated: Bool) {
        guard let token else { throw GitHubError(status: 401) }
        var repos: [GitHubRepoSummary] = []
        var next: String? = "https://api.github.com/user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100"
        for _ in 0..<Self.repoPageCap {
            guard let url = next else { break }
            let page: ([GitHubRepoSummary], String?) = try await getPage(url, token: token)
            repos += page.0
            next = page.1
        }
        return (repos, next != nil)
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = try? JSONDecoder().decode(SignInRefusal.Body.self, from: data)
            throw SignInRefusal(status: status, code: body?.error, description: body?.error_description ?? body?.message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// GitHub refused a sign-in request: a plain sentence for the user, and
    /// GitHub's own words for "Show details".
    struct SignInRefusal: Error, Equatable {
        struct Body: Decodable { var error: String?; var error_description: String?; var message: String? }
        var status: Int
        var code: String?
        var description: String?

        var message: String {
            switch code {
            case "device_flow_disabled":
                String(localized: "Sign-in with GitHub is turned off for Mux Bot's GitHub App. Its owner needs to switch on Device Flow in the App's settings.")
            case "incorrect_client_credentials", "unauthorized_client":
                String(localized: "This Mux Bot build isn't set up to sign in with GitHub.")
            default:
                String(localized: "GitHub sign-in didn't work. Try again in a moment.")
            }
        }

        var details: String {
            ["GitHub answered \(status)", code, description].compactMap { $0 }.joined(separator: ": ")
        }
    }

    /// One page, and the next page's URL from the Link header, if any.
    private func getPage<T: Decodable>(_ url: String, token: String) async throws -> (T, String?) {
        guard let address = URL(string: url) else { throw GitHubError(status: 0) }
        var request = URLRequest(url: address)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else { throw GitHubError(status: http?.statusCode ?? 0) }
        return (try JSONDecoder().decode(T.self, from: data), Self.nextPage(http?.value(forHTTPHeaderField: "Link")))
    }

    /// `<https://…&page=2>; rel="next", <…>; rel="last"` → the next URL.
    /// Only back to api.github.com, since the request carries your token.
    nonisolated static func nextPage(_ link: String?) -> String? {
        for part in (link ?? "").split(separator: ",") where part.contains(#"rel="next""#) {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close else { continue }
            let url = String(part[part.index(after: open)..<close])
            return URLComponents(string: url).map { $0.scheme == "https" && $0.host == "api.github.com" } == true ? url : nil
        }
        return nil
    }
}
