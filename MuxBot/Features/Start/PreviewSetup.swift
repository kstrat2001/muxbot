import Foundation
#if os(macOS)
import AppKit
#endif

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
        case noPermission
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .exists: String(localized: "That file is already there; I never overwrite it.")
            case let .notYourCheckout(name): String(localized: "That isn't this bot's checkout. Choose \(name).")
            case .symlink: String(localized: "A folder on the way is a link, so I won't write through it.")
            case .noPermission: String(localized: "Mux Bot isn't allowed to write into that folder.")
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
        } catch let error as NSError where Self.isNoPermission(error) {
            // Read-only access (a bookmark kept before writes asked once).
            throw .noPermission
        } catch {
            throw .failed(error.localizedDescription)
        }
    }

    static func isNoPermission(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(error.code) { return true }
        if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isNoPermission(under) }
        return false
    }

    /// The folder you chose is the bot's checkout (the panel can't be locked
    /// to one folder).
    static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// package.json's text and the names at the root of your checkout, read
    /// through its bookmark.
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

extension PreviewSetup {
    private static let managers: Set<String> = ["npm", "pnpm", "yarn", "bun"]

    /// How the preview runs, in words: the commands darkmux runs stay behind
    /// Show details on the card.
    static func howItRuns(command: String, install: String) -> String {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return String(localized: "How it starts isn't known yet: fill it in under Show details.") }
        let script: String? = {
            guard let tool = words.first, managers.contains(tool), words.count >= 2 else { return nil }
            return words[1] == "run" ? (words.count >= 3 ? words[2] : nil) : words[1]
        }()
        let starts = script.map { String(localized: "Starts with its \($0) script") } ?? String(localized: "Starts with its own command")
        guard let manager = install.split(whereSeparator: \.isWhitespace).first.map(String.init), managers.contains(manager) else {
            return starts + "."
        }
        return starts + String(localized: "; installs with \(manager).")
    }
}

/// Writing a new file into your checkout (a setup card's Approve). The
/// folder's permission is asked for once, when you add it: Add folder keeps
/// a read-write bookmark (`bookmarkOptions`), so Approve writes with no
/// picker. A bookmark kept read-only (added before) asks once more, with the
/// panel on that folder; only that same folder is accepted, and its bookmark
/// is kept read-write from then on. Never over an existing file
/// (`PreviewSetup.writeNew`).
@MainActor
enum CheckoutWrite {
    struct Deps {
        var resolve: (Data) -> URL?
        var write: (Data, String, URL) throws(PreviewSetup.WriteError) -> Void
        /// The Open panel, started on the given folder; nil when canceled.
        var ask: (URL?) -> URL?
        var bookmark: (URL) -> Data?
    }

    #if os(macOS)
    /// Read-write: asked once, when you add the folder.
    static let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    #endif

    static func differentFolder(bot: Bot) -> String {
        String(localized: "That's a different folder from the one \(bot.name) uses. Pick \(bot.folderName ?? bot.name).")
    }

    static func perform(_ data: Data, at path: String, bot: Bot, deps: Deps) -> String? {
        let checkout = bot.folderBookmark.flatMap { $0.isEmpty ? nil : deps.resolve($0) }
        if let checkout {
            do {
                try deps.write(data, path, checkout)
                return nil
            } catch .noPermission {
                // Kept read-only: ask once, below.
            } catch {
                return error.localizedDescription
            }
        }
        guard let chosen = deps.ask(checkout) else { return String(localized: "Nothing was written.") }
        if let checkout, !PreviewSetup.sameFolder(chosen, checkout) { return differentFolder(bot: bot) }
        do {
            try deps.write(data, path, chosen)
        } catch {
            return error.localizedDescription
        }
        // From now on it writes without asking.
        if checkout != nil, let upgraded = deps.bookmark(chosen) { bot.folderBookmark = upgraded }
        return nil
    }

    #if os(macOS)
    static func approve(_ data: Data, at path: String, bot: Bot) -> String? {
        perform(data, at: path, bot: bot, deps: Deps(
            resolve: RunCoordinator.resolve(bookmark:),
            write: { data, path, folder throws(PreviewSetup.WriteError) in
                let accessing = folder.startAccessingSecurityScopedResource()
                defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
                try PreviewSetup.writeNew(data, at: path, into: folder)
            },
            ask: { start in
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.directoryURL = start
                let name = bot.folderName ?? start?.lastPathComponent ?? bot.name
                panel.message = String(localized: "Choose \(name) once so Mux Bot can write into it from now on.")
                panel.prompt = String(localized: "Allow")
                return panel.runModal() == .OK ? panel.url : nil
            },
            bookmark: { try? $0.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) }))
    }
    #endif
}
