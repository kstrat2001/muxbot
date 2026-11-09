import Foundation

/// A preview recipe Mux Bot offers to set up for a project that has none,
/// on an Approve card: each value editable, with where it was found
/// (`ProjectSetupDetector`, rules only). On Approve the exact file is
/// written into your own checkout, uncommitted (darkmux reads a recipe only
/// from there), and goes into the bot's next pull request.
struct PreviewSetup: Codable, Equatable, Sendable {
    static let path = ".darkmux/preview.json"

    /// A value and where it came from; nil `source` means the rules didn't
    /// find it and you fill it in.
    struct Field: Codable, Equatable, Sendable {
        var value: String
        var source: String?
    }

    var framework: String?
    var command: Field
    var install: Field
    /// The dev server's environment, as `KEY=value` pairs separated by
    /// spaces (`{port}` is the port darkmux picks).
    var env: Field
    var ready: Field
    /// Whether edits show up live; darkmux's recipe has no switch for it.
    var hotReload: Field
    var envFromSource: [String]
    /// Your checkout's folder name, for the card.
    var folderName: String

    init(_ draft: ProjectSetupDetector.Draft, folderName: String) {
        framework = draft.framework?.value
        command = Field(value: draft.command?.value ?? "", source: draft.command?.source)
        install = Field(value: draft.install?.value ?? "", source: draft.install?.source)
        switch draft.port?.value {
        case let .env(pairs)?: env = Field(value: Self.text(pairs), source: draft.port?.source)
        case .flags?: env = Field(value: "PORT={port}", source: draft.port?.source)
        case nil: env = Field(value: "", source: nil)
        }
        ready = Field(value: draft.ready?.value ?? "", source: draft.ready?.source)
        hotReload = Field(value: draft.hotReload.map { $0.value ? String(localized: "yes") : String(localized: "no") } ?? "",
                          source: draft.hotReload?.source)
        envFromSource = draft.envFromSource?.value ?? []
        self.folderName = folderName
    }

    static func text(_ pairs: [String: String]) -> String {
        pairs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    static func pairs(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in text.split(whereSeparator: \.isWhitespace) {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, !kv[0].isEmpty { out[kv[0]] = kv[1] }
        }
        return out
    }

    /// The file exactly as it's written: darkmux's recipe shape
    /// (`schema_version` "1.0", only the keys darkmux reads). nil without a
    /// command.
    var recipeData: Data? {
        let command = command.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        var recipe: [String: Any] = ["schema_version": "1.0", "command": command]
        let env = Self.pairs(env.value)
        if !env.isEmpty { recipe["env"] = env }
        let ready = ready.value.trimmingCharacters(in: .whitespaces)
        if !ready.isEmpty { recipe["ready"] = ["http": ready.hasPrefix("/") ? ready : "/" + ready] }
        let install = install.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !install.isEmpty { recipe["install"] = ["command": install, "unless_exists": "node_modules"] }
        if !envFromSource.isEmpty { recipe["env_from_source"] = envFromSource }
        guard var data = try? JSONSerialization.data(withJSONObject: recipe, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        data.append(0x0A)
        return data
    }

    enum WriteError: Error, Equatable, LocalizedError {
        case exists
        case notYourCheckout(String)
        case symlink
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .exists: String(localized: "That file is already there; I never overwrite it.")
            case let .notYourCheckout(name): String(localized: "That isn't this bot's checkout. Choose \(name).")
            case .symlink: String(localized: "A folder on the way is a link, so I won't write through it.")
            case let .failed(why): String(localized: "Couldn't write it: \(why)")
            }
        }
    }

    /// Writes `data` as `.darkmux/preview.json` in `folder` (your checkout),
    /// never over an existing file or through a symlinked `.darkmux`.
    static func write(_ data: Data, into folder: URL) throws(WriteError) {
        try writeNew(data, at: path, into: folder)
    }

    /// Writes `data` at `relativePath` in `folder`, only as a new file: never
    /// over one that exists, never through a symlinked folder on the way.
    static func writeNew(_ data: Data, at relativePath: String, into folder: URL) throws(WriteError) {
        let fm = FileManager.default
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let last = parts.last, !parts.contains(".."), !relativePath.hasPrefix("/") else { throw .failed("not a plain relative path") }
        var dir = folder
        for part in parts.dropLast() {
            dir = dir.appendingPathComponent(part, isDirectory: true)
            if let kind = try? fm.attributesOfItem(atPath: dir.path)[.type] as? FileAttributeType, kind == .typeSymbolicLink { throw .symlink }
        }
        let file = dir.appendingPathComponent(last)
        if fm.fileExists(atPath: file.path) || (try? fm.destinationOfSymbolicLink(atPath: file.path)) != nil { throw .exists }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // withoutOverwriting: if one appears in the meantime, it stays.
            try data.write(to: file, options: [.withoutOverwriting])
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw .exists
        } catch {
            throw .failed(error.localizedDescription)
        }
    }

    /// The folder you chose is the bot's checkout (the panel can't be locked
    /// to one folder).
    static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// package.json's text and the names at the root of your checkout, read
    /// through its bookmark (read-only).
    static func readCheckout(_ folder: URL) -> (packageJSON: String?, files: Set<String>) {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let pkg = folder.appendingPathComponent("package.json")
        let size = (try? pkg.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let text = size > 0 && size <= 512 * 1024 ? try? String(contentsOf: pkg, encoding: .utf8) : nil
        return (text, names)
    }
}
