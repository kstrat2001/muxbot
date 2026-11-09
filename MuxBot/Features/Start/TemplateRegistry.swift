import Foundation

/// One use case in the template registry: a template repo at a pinned ref.
struct TemplateEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// `owner/name` on GitHub.
    var repo: String
    /// A tag or commit; never a branch.
    var ref: String
    var title: String
    var icon: String

    var repoURL: String { "https://github.com/\(repo)" }
}

/// The templates Mux Bot offers ("What do you want to get done?"): read
/// unauthenticated from GitHub (`kstrat2001/muxbot-templates`'s
/// templates.json), kept in a cache, and built into the app for when
/// neither is there. Templates are used only at their pinned ref: setting
/// one up runs its install on this Mac, and its PLAYBOOK.md is read by the
/// bots' models.
final class TemplateRegistry: Sendable {
    typealias Fetch = @Sendable (URL) async throws -> Data

    static let listURL = URL(string: "https://raw.githubusercontent.com/kstrat2001/muxbot-templates/main/templates.json")!

    private let cacheURL: URL
    private let fetch: Fetch

    init(cacheURL: URL = TemplateRegistry.defaultCacheURL, fetch: @escaping Fetch = TemplateRegistry.download) {
        self.cacheURL = cacheURL
        self.fetch = fetch
    }

    static let shared = TemplateRegistry()

    static var defaultCacheURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("templates.json")
    }

    @Sendable static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// The list: fresh from GitHub (and cached), else the cache, else the
    /// copy built into the app.
    func templates() async -> [TemplateEntry] {
        if let data = try? await fetch(Self.listURL), let entries = try? Self.decode(data), !entries.isEmpty {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            return entries
        }
        if let data = try? Data(contentsOf: cacheURL), let entries = try? Self.decode(data), !entries.isEmpty {
            return entries
        }
        return Self.bundledTemplates()
    }

    /// A template's playbook at its pinned ref; the copy built into the app
    /// when it can't be fetched or doesn't parse.
    func playbook(for entry: TemplateEntry) async -> Playbook? {
        let url = URL(string: "https://raw.githubusercontent.com/\(entry.repo)/\(entry.ref)/PLAYBOOK.md")!
        if let data = try? await fetch(url), let text = String(data: data, encoding: .utf8),
           let playbook = try? Playbook.parse(text) {
            return playbook
        }
        return Self.bundledPlaybook(for: entry.id)
    }

    // MARK: The list's format

    private struct List: Decodable {
        var version: Int
        var templates: [TemplateEntry]
    }

    /// Entries that are usable: an `owner/name` repo and a pinned ref (a
    /// tag or a commit, never a branch name like main).
    static func decode(_ data: Data) throws -> [TemplateEntry] {
        try JSONDecoder().decode(List.self, from: data).templates.filter { isRepo($0.repo) && isPinned($0.ref) }
    }

    static func isRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    static func isPinned(_ ref: String) -> Bool {
        let branches: Set<String> = ["", "main", "master", "develop", "dev", "HEAD", "trunk"]
        return !branches.contains(ref) && !ref.contains("..") && !ref.contains(" ")
    }

    // MARK: Built into the app (Start/Templates)

    static func bundledTemplates() -> [TemplateEntry] {
        guard let url = Bundle.main.url(forResource: "templates", withExtension: "json", subdirectory: "Templates"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data)) ?? []
    }

    static func bundledPlaybook(for id: String) -> Playbook? {
        guard let url = Bundle.main.url(forResource: "\(id).PLAYBOOK", withExtension: "md", subdirectory: "Templates"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? Playbook.parse(text)
    }
}
