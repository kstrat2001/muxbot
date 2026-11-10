import Foundation

/// Makes a new project's own GitHub repo with your sign-in: a repo in your
/// account (private unless you choose public), filled with the template's
/// files as of its pinned commit as one commit. No fork and no link back to
/// the template. GitHub's Git Data API can't write to an empty repo, so the
/// repo starts with GitHub's own first commit and the template's files go on
/// top of it (replacing that commit's README), moving the default branch
/// forward without force.
struct GitHubRepoMaker: Sendable {
    struct Made: Equatable, Sendable {
        /// `owner/name`.
        var repo: String
        var url: URL
        var defaultBranch: String
        /// The commit holding the template's files: the project's start.
        var startCommit: String
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// The Mux Bot GitHub App may not create repositories (it needs the
        /// "Repository creation" permission).
        case cantCreate
        /// No free name close to the one asked for.
        case noFreeName(String)
        /// Something didn't fit: a template tree GitHub cut short, a
        /// submodule.
        case template(String)
        /// The repo was made but its files couldn't be added: it's there,
        /// empty but for GitHub's first commit.
        case madeButNotFilled(repo: String, why: String)
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
                String(localized: "Mux Bot's GitHub App isn't allowed to create repositories yet. In the App's settings on GitHub, give it the \u{201C}Repository creation\u{201D} permission, then approve the update.")
            case let .noFreeName(name):
                String(localized: "You already have repos named \(name) and the next few after it. Pick another name.")
            case let .template(why):
                String(localized: "The template can't be copied: \(why)")
            case let .madeButNotFilled(repo, why):
                String(localized: "I made github.com/\(repo), but couldn't add the template's files to it (\(why)). It's empty: delete it on GitHub or try again with another name.")
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

    /// A repo made from `template` (its "Start from <template>@<commit>"
    /// commit on the default branch): where the bot's work builds on GitHub,
    /// and the template commit it started from (the pinned one, or the
    /// older pin it was made at). nil when the repo has no such commit.
    func findStart(repo: String, template: TemplateEntry, botName: String) async throws -> (start: GitHubPR.Start, ref: String)? {
        struct Repo: Decodable { var default_branch: String? }
        struct Commit: Decodable { struct Inner: Decodable { var message: String }; var sha: String; var commit: Inner }
        struct SHA: Decodable { var sha: String }
        let info: Repo = try await send("GET", "https://api.github.com/repos/\(repo)", nil)
        let branch = info.default_branch ?? "main"
        let commits: [Commit] = try await send("GET", "https://api.github.com/repos/\(repo)/commits?sha=\(branch)&per_page=100", nil)
        let prefix = "Start from \(template.repo)@"
        guard let start = commits.first(where: { $0.commit.message.hasPrefix(prefix) }) else { return nil }
        let short = String(start.commit.message.dropFirst(prefix.count).prefix { $0.isHexDigit })
        guard !short.isEmpty else { return nil }
        var ref = template.ref
        if !template.ref.hasPrefix(short) {
            let full: SHA = try await send("GET", "https://api.github.com/repos/\(template.repo)/commits/\(short)", nil)
            ref = full.sha
        }
        return (GitHubPR.Start(commit: start.sha, branch: branch, head: "mux/\(Self.slug(botName))"), ref)
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

    /// Makes the repo and fills it with `template` at its pinned commit.
    /// The template is read and checked first, so one that can't be copied
    /// leaves no empty repo behind; a name GitHub says is taken (one that
    /// appeared since `freeName` looked, or one it couldn't see) moves on to
    /// the next.
    func make(name: String, isPrivate: Bool, description: String, from template: TemplateEntry) async throws -> Made {
        struct Created: Decodable { var full_name: String; var html_url: String; var default_branch: String? }
        let tree = try await templateTree(template)
        var candidate = name
        var made: Created?
        for _ in 0...Self.nameTries {
            do {
                made = try await send("POST", "https://api.github.com/user/repos",
                                      ["name": candidate, "private": isPrivate, "description": Self.describe(description), "auto_init": true])
                break
            } catch Failure.refused(let status, _) where status == 403 || status == 404 {
                throw Failure.cantCreate
            } catch Failure.refused(422, let why) where why.localizedCaseInsensitiveContains("already exists") {
                candidate = Self.nextName(candidate)
            }
        }
        guard let created = made else { throw Failure.noFreeName(name) }
        let repo = created.full_name
        do {
            let branch = created.default_branch ?? "main"
            let start = try await fill(repo: repo, branch: branch, tree: tree, from: template)
            return Made(repo: repo, url: URL(string: created.html_url) ?? URL(string: "https://github.com/\(repo)")!,
                        defaultBranch: branch, startCommit: start)
        } catch {
            throw Failure.madeButNotFilled(repo: repo, why: error.localizedDescription)
        }
    }

    /// The template's file list at its pinned commit, refused when it can't
    /// be copied whole (GitHub cut the list short, or a submodule).
    struct TemplateTree: Decodable, Sendable {
        struct Entry: Decodable, Sendable { var path: String; var mode: String; var type: String; var sha: String }
        var tree: [Entry]
        var truncated: Bool?
    }

    func templateTree(_ template: TemplateEntry) async throws -> TemplateTree {
        let tree: TemplateTree = try await send("GET", "https://api.github.com/repos/\(template.repo)/git/trees/\(template.ref)?recursive=1", nil)
        if tree.truncated == true { throw Failure.template(String(localized: "it has more files than GitHub lists at once")) }
        if let sub = tree.tree.first(where: { $0.type == "commit" }) {
            throw Failure.template(String(localized: "it has a submodule (\(sub.path))"))
        }
        return tree
    }

    /// The template's files at its pinned commit, as one commit on top of
    /// the new repo's first one. Returns that commit.
    func fill(repo: String, branch: String, tree: TemplateTree, from template: TemplateEntry) async throws -> String {
        struct Blob: Decodable { var content: String; var encoding: String }
        struct SHA: Decodable { var sha: String }
        struct Ref: Decodable { struct Object: Decodable { var sha: String }; var object: Object }

        let source = "https://api.github.com/repos/\(template.repo)"
        let api = "https://api.github.com/repos/\(repo)"
        var entries: [[String: Any]] = []
        for file in tree.tree where file.type == "blob" {
            let blob: Blob = try await send("GET", "\(source)/git/blobs/\(file.sha)", nil)
            let copied: SHA = try await send("POST", "\(api)/git/blobs",
                                             ["content": blob.content.replacingOccurrences(of: "\n", with: ""), "encoding": blob.encoding])
            entries.append(["path": file.path, "mode": file.mode, "type": "blob", "sha": copied.sha])
        }
        // No base tree: the repo holds exactly the template's files.
        let newTree: SHA = try await send("POST", "\(api)/git/trees", ["tree": entries])
        let head: Ref = try await send("GET", "\(api)/git/ref/heads/\(branch)", nil)
        let short = String(template.ref.prefix(7))
        let commit: SHA = try await send("POST", "\(api)/git/commits",
                                         ["message": "Start from \(template.repo)@\(short)", "tree": newTree.sha, "parents": [head.object.sha]])
        let _: [String: AnyCodable] = try await send("PATCH", "\(api)/git/refs/heads/\(branch)", ["sha": commit.sha, "force": false])
        return commit.sha
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
        let (data, response) = try await session.data(for: try request(method, url, body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 401 else { return (data, status) }
        guard let fresh = await GitHubSession.renewed() else { throw Failure.signInExpired }
        current.value = fresh
        let (again, retried) = try await session.data(for: try request(method, url, body))
        let second = (retried as? HTTPURLResponse)?.statusCode ?? 0
        if second == 401 { throw Failure.signInExpired }
        return (again, second)
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
