import Foundation

/// Makes a new project's own GitHub repo with your sign-in: an empty repo
/// in your account (private unless you choose public). The project's first
/// push from darkmux (darkmux #3681) fills it with the project's own
/// history, so GitHub and the work copy share one history from the start.
struct GitHubRepoMaker: Sendable {
    struct Made: Equatable, Sendable {
        /// `owner/name`.
        var repo: String
        var url: URL
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// The Mux Bot GitHub App may not create repositories for this
        /// account (its "Repository creation" permission, which only the
        /// App's owner sets; you approve an update when GitHub asks).
        case cantCreate
        /// No free name close to the one asked for.
        case noFreeName(String)
        /// Something didn't fit: a template tree GitHub cut short, a
        /// submodule.
        case template(String)
        /// Put it on GitHub made the repo (and recorded it), but the
        /// project's work isn't in it yet: Put again finishes into it.
        case notPushedYet(repo: String, why: String)
        /// GitHub stopped taking the sign-in and it couldn't be renewed.
        case signInExpired
        /// GitHub refused a request; `message` is its own reason.
        case refused(status: Int, message: String)
        case github(String)
        /// The app's own sentence (not GitHub's words).
        case plain(String)

        var errorDescription: String? {
            switch self {
            case .cantCreate:
                String(localized: "Mux Bot's GitHub App can't create repositories for your account yet. If GitHub has asked you to approve updated permissions for it, approve them, then try again. A new project can also start on this Mac only: switch Back up to GitHub off.")
            case let .noFreeName(name):
                String(localized: "You already have repos named \(name) and the next few after it. Pick another name.")
            case let .template(why):
                String(localized: "The template can't be copied: \(why)")
            case let .notPushedYet(repo, why):
                String(localized: "I made github.com/\(repo), but couldn't put this project's work in it yet (\(why)). Choose Finish putting it on GitHub to try again; it goes into the same repo.")
            case .signInExpired:
                GitHubAuth.expiredMessage
            case let .refused(status, message):
                message.isEmpty ? GitHubPlain.sentence(status: status, signedIn: true) : String(localized: "GitHub said: \(message)")
            case let .github(why):
                String(localized: "GitHub said: \(why)")
            case let .plain(text): text
            }
        }
    }

    var session: URLSession = .shared
    /// Waits between tries while a new repo's first commit lands (tests skip it).
    var pause: @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    private let current: GitHubToken
    var token: String { current.value }

    init(session: URLSession = .shared, token: String) {
        self.session = session
        current = GitHubToken(token)
    }

    /// GitHub takes a repo description of one line up to 350 characters:
    /// the project's purpose on one line, cut at a word when it's longer.
    static let descriptionLimit = 350
    static func describe(_ purpose: String) -> String {
        let line = purpose.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > descriptionLimit else { return line }
        let cut = line.prefix(descriptionLimit - 1)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(atWord) + "\u{2026}"
    }

    /// "site" → "site-2", "site-2" → "site-3".
    static func nextName(_ name: String) -> String {
        if let dash = name.lastIndex(of: "-"), let n = Int(name[name.index(after: dash)...]), n >= 2 {
            return "\(name[..<dash])-\(n + 1)"
        }
        return "\(name)-2"
    }
    /// How many names after the first to try ("site", "site-2", …).
    static let nameTries = 10

    /// A repo name from the project's: lowercase letters, digits and dashes.
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let ascii = collapsed.unicodeScalars.filter { $0.isASCII }.map(String.init).joined()
        return ascii.isEmpty ? "project" : String(ascii.prefix(90))
    }

    /// Your login.
    func login() async throws -> String {
        struct User: Decodable { var login: String }
        let user: User = try await send("GET", "https://api.github.com/user", nil)
        return user.login
    }

    /// `name`, else the first of "name-2", "name-3"… that you don't have.
    func freeName(_ name: String, owner: String) async throws -> String {
        for n in 1...(Self.nameTries + 1) {
            let candidate = n == 1 ? name : "\(name)-\(n)"
            let existing: [String: AnyCodable]? = try await sendOptional("GET", "https://api.github.com/repos/\(owner)/\(candidate)")
            if existing == nil { return candidate }
            _ = existing
        }
        throw Failure.noFreeName(name)
    }

    /// Makes the empty repo. A name GitHub says is taken (one that appeared
    /// since `freeName` looked, or one it couldn't see) moves on to the next.
    func make(name: String, isPrivate: Bool, description: String) async throws -> Made {
        struct Created: Decodable { var full_name: String; var html_url: String }
        var candidate = name
        for _ in 0...Self.nameTries {
            do {
                let created: Created = try await send("POST", "https://api.github.com/user/repos",
                                                      ["name": candidate, "private": isPrivate, "description": Self.describe(description), "auto_init": false])
                return Made(repo: created.full_name, url: URL(string: created.html_url) ?? URL(string: "https://github.com/\(created.full_name)")!)
            } catch Failure.refused(let status, _) where status == 403 || status == 404 {
                throw Failure.cantCreate
            } catch Failure.refused(422, let why) where why.localizedCaseInsensitiveContains("already exists") {
                candidate = Self.nextName(candidate)
            }
        }
        throw Failure.noFreeName(name)
    }

    // MARK: - Requests

    private func request(_ method: String, _ url: String, _ body: [String: Any]?) throws -> URLRequest {
        guard let address = URL(string: url) else { throw Failure.github("bad URL") }
        var request = URLRequest(url: address)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// One request; a 401 renews the sign-in once and retries with it.
    private func load(_ method: String, _ url: String, _ body: [String: Any]?) async throws -> (Data, Int) {
        let (data, status, _) = try await loadLinked(method, url, body)
        return (data, status)
    }

    /// One page of a list, with its Link header (the other pages).
    private func page<T: Decodable>(_ url: String) async throws -> (T, String?) {
        let (data, status, link) = try await loadLinked("GET", url, nil)
        guard (200..<300).contains(status) else { throw Failure.refused(status: status, message: Self.reason(data)) }
        return (try JSONDecoder().decode(T.self, from: data), link)
    }

    private func loadLinked(_ method: String, _ url: String, _ body: [String: Any]?) async throws -> (Data, Int, String?) {
        let (data, response) = try await session.data(for: try request(method, url, body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 401 else { return (data, status, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link")) }
        let fresh: String
        switch await GitHubSession.renewed() {
        case let .token(token): fresh = token
        case .expired: throw Failure.signInExpired
        case .unreachable: throw Failure.refused(status: 0, message: "")
        }
        current.value = fresh
        let (again, retried) = try await session.data(for: try request(method, url, body))
        let second = (retried as? HTTPURLResponse)?.statusCode ?? 0
        if second == 401 { throw Failure.signInExpired }
        return (again, second, (retried as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link"))
    }

    private func send<T: Decodable>(_ method: String, _ url: String, _ body: [String: Any]?) async throws -> T {
        let (data, status) = try await load(method, url, body)
        guard (200..<300).contains(status) else { throw Failure.refused(status: status, message: Self.reason(data)) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// GitHub's own reason: its first error's message (the specific one,
    /// "description is too long"), else its message.
    static func reason(_ data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let first = (json?["errors"] as? [[String: Any]])?.first?["message"] as? String
        return first ?? json?["message"] as? String ?? ""
    }

    /// A GET whose 404 means "not there" (nil).
    private func sendOptional<T: Decodable>(_ method: String, _ url: String) async throws -> T? {
        let (data, status) = try await load(method, url, nil)
        if status == 404 { return nil }
        guard status == 200 else { throw Failure.refused(status: status, message: Self.reason(data)) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
