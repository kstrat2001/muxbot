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
        case github(String)

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
            case let .github(why):
                String(localized: "GitHub said: \(why)")
            }
        }
    }

    var session: URLSession = .shared
    let token: String
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
        }
        throw Failure.noFreeName(name)
    }

    /// Makes the repo and fills it with `template` at its pinned commit.
    func make(name: String, isPrivate: Bool, description: String, from template: TemplateEntry) async throws -> Made {
        struct Created: Decodable { var full_name: String; var html_url: String; var default_branch: String? }
        let created: Created
        do {
            created = try await send("POST", "https://api.github.com/user/repos",
                                     ["name": name, "private": isPrivate, "description": description, "auto_init": true])
        } catch Failure.github(let why) where why.hasPrefix("403") || why.hasPrefix("404") {
            throw Failure.cantCreate
        }
        let repo = created.full_name
        do {
            let branch = created.default_branch ?? "main"
            let start = try await fill(repo: repo, branch: branch, from: template)
            return Made(repo: repo, url: URL(string: created.html_url) ?? URL(string: "https://github.com/\(repo)")!,
                        defaultBranch: branch, startCommit: start)
        } catch {
            throw Failure.madeButNotFilled(repo: repo, why: error.localizedDescription)
        }
    }

    /// The template's files at its pinned commit, as one commit on top of
    /// the new repo's first one. Returns that commit.
    func fill(repo: String, branch: String, from template: TemplateEntry) async throws -> String {
        struct Tree: Decodable {
            struct Entry: Decodable { var path: String; var mode: String; var type: String; var sha: String }
            var tree: [Entry]
            var truncated: Bool?
        }
        struct Blob: Decodable { var content: String; var encoding: String }
        struct SHA: Decodable { var sha: String }
        struct Ref: Decodable { struct Object: Decodable { var sha: String }; var object: Object }

        let source = "https://api.github.com/repos/\(template.repo)"
        let tree: Tree = try await send("GET", "\(source)/git/trees/\(template.ref)?recursive=1", nil)
        if tree.truncated == true { throw Failure.template(String(localized: "it has more files than GitHub lists at once")) }
        if let sub = tree.tree.first(where: { $0.type == "commit" }) {
            throw Failure.template(String(localized: "it has a submodule (\(sub.path))"))
        }
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

    private func send<T: Decodable>(_ method: String, _ url: String, _ body: [String: Any]?) async throws -> T {
        let (data, response) = try await session.data(for: try request(method, url, body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
            throw Failure.github("\(status) \(message)".trimmingCharacters(in: .whitespaces))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A GET whose 404 means "not there" (nil).
    private func sendOptional<T: Decodable>(_ method: String, _ url: String) async throws -> T? {
        let (data, response) = try await session.data(for: try request(method, url, nil))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw Failure.github("\(status)") }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
