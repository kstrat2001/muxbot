import Foundation

/// One use case in the template registry: a template repo at a pinned ref.
struct TemplateEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String
    /// `owner/name` on GitHub.
    var repo: String
    /// A full commit SHA: the template is used only as of this commit.
    var ref: String
    var title: String
    var icon: String
    var summary: String? = nil

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

    /// A template at its pinned commit: its playbook, once its PLAYBOOK.md
    /// and .darkmux/preview.json pass the schema, or why it can't be used.
    /// Offline, the copies built into the app.
    func template(for entry: TemplateEntry) async -> TemplateDetails {
        let base = "https://raw.githubusercontent.com/\(entry.repo)/\(entry.ref)/"
        if let playbook = try? await fetch(URL(string: base + "PLAYBOOK.md")!),
           let preview = try? await fetch(URL(string: base + ".darkmux/preview.json")!) {
            return Self.check(playbook: playbook, preview: preview)
        }
        guard let bundled = Self.bundledFiles(for: entry.id) else {
            return .refused(String(localized: "Mux Bot can't reach GitHub to read this template."))
        }
        return Self.check(playbook: bundled.playbook, preview: bundled.preview)
    }

    static func check(playbook: Data, preview: Data) -> TemplateDetails {
        do {
            let parsed = try Playbook.parse(String(decoding: playbook, as: UTF8.self))
            // Schema 2: the preview is darkmux's own recipe.
            try TemplateSchema.checkPreview(preview, darkmuxShape: parsed.schema >= 2)
            return .ready(parsed)
        } catch let error as Playbook.ParseError {
            return .refused(error.message)
        } catch let error as TemplateSchema.Problem {
            return .refused(error.message)
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    // MARK: The list's format

    static let listKeys = ["schema", "templates"]
    static let entryKeys = ["id", "repo", "ref", "title", "icon", "summary"]

    /// The usable entries of a schema-1 list: an `owner/name` repo pinned
    /// to a full commit SHA, and no key the schema doesn't name. A list
    /// with no schema, or a newer one, is refused.
    static func decode(_ data: Data) throws -> [TemplateEntry] {
        let file = "templates.json"
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TemplateSchema.Problem.invalid(file: file, key: "(file)", why: String(localized: "it isn't a JSON object."))
        }
        for key in object.keys.sorted() where !listKeys.contains(key) {
            throw TemplateSchema.Problem.unknownKey(file: file, key: key, closest: TemplateSchema.closest(to: key, in: listKeys))
        }
        let schema = (object["schema"] as? Int).map(String.init) ?? (object["schema"] as? String)
        try TemplateSchema.check(schema, missing: TemplateSchema.Problem.missingSchema(file: file),
                                 newer: { TemplateSchema.Problem.newerSchema(file: file, $0) },
                                 notANumber: { TemplateSchema.Problem.notASchema(file: file, $0) })
        let raw = object["templates"] as? [[String: Any]] ?? []
        return raw.compactMap { item -> TemplateEntry? in
            guard item.keys.allSatisfy(entryKeys.contains),
                  let entryData = try? JSONSerialization.data(withJSONObject: item),
                  let entry = try? JSONDecoder().decode(TemplateEntry.self, from: entryData),
                  isRepo(entry.repo), isPinned(entry.ref) else { return nil }
            return entry
        }
    }

    static func isRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }

    /// A full commit SHA: never a branch or a tag, which can move.
    static func isPinned(_ ref: String) -> Bool {
        ref.count == 40 && ref.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    // MARK: Built into the app (Start/Templates)

    static func bundledTemplates() -> [TemplateEntry] {
        guard let url = Bundle.main.url(forResource: "templates", withExtension: "json", subdirectory: "Templates"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data)) ?? []
    }

    static func bundledFiles(for id: String) -> (playbook: Data, preview: Data)? {
        guard let playbook = Bundle.main.url(forResource: "\(id).PLAYBOOK", withExtension: "md", subdirectory: "Templates"),
              let preview = Bundle.main.url(forResource: "\(id).preview", withExtension: "json", subdirectory: "Templates"),
              let p = try? Data(contentsOf: playbook), let r = try? Data(contentsOf: preview) else { return nil }
        return (p, r)
    }

    static func bundledPlaybook(for id: String) -> Playbook? {
        guard let files = bundledFiles(for: id), case let .ready(playbook) = check(playbook: files.playbook, preview: files.preview) else { return nil }
        return playbook
    }
}

/// A template as the start screen can use it.
enum TemplateDetails: Equatable, Sendable {
    case ready(Playbook)
    /// Why it can't be used, in plain words ("This template needs a newer
    /// Mux Bot ...").
    case refused(String)

    var playbook: Playbook? { if case let .ready(p) = self { p } else { nil } }
}
