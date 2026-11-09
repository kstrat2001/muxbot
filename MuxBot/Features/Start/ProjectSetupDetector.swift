import Foundation

/// Works out a project's preview recipe from its own files, by rules only:
/// `package.json`'s dev script for the command, the
/// framework, how it takes a port and whether it hot-reloads, and the
/// lockfile for the install. Every value says where it was found; what the
/// rules can't find is left blank for you, never invented.
enum ProjectSetupDetector {
    /// A detected value and where it came from ("found in package.json: …").
    struct Found<Value: Equatable & Sendable>: Equatable, Sendable {
        var value: Value
        var source: String
    }

    /// How the dev server is told its port. darkmux substitutes `{port}`
    /// only in `env`, and runs the command through `sh`, so flags read the
    /// port from `$PORT`, which the recipe sets.
    enum PortStyle: Equatable, Sendable {
        /// Arguments added to the command, reading `$PORT`.
        case flags(String)
        /// Environment variables, with `{port}`.
        case env([String: String])
    }

    struct Draft: Equatable, Sendable {
        var framework: Found<String>?
        var command: Found<String>?
        var install: Found<String>?
        var port: Found<PortStyle>?
        var hotReload: Found<Bool>?
        var ready: Found<String>?
        var envFromSource: Found<[String]>?

        /// Nothing the rules could use: no package.json, or no dev script.
        var isEmpty: Bool { command == nil && install == nil }
    }

    private struct Package: Decodable {
        var scripts: [String: String]?
        var dependencies: [String: String]?
        var devDependencies: [String: String]?
    }

    private enum Manager: String {
        case npm, pnpm, yarn, bun

        func run(_ script: String) -> String {
            switch self {
            case .npm: "npm run \(script)"
            case .pnpm: "pnpm \(script)"
            case .yarn: "yarn \(script)"
            case .bun: "bun run \(script)"
            }
        }

        /// Extra arguments after the script's own.
        func passing(_ args: String) -> String { self == .npm ? " -- \(args)" : " \(args)" }
    }

    /// `packageJSON` is the root package.json's text (nil when there is
    /// none); `files` are the names at the project's root.
    static func detect(packageJSON: String?, files: Set<String>) -> Draft {
        var draft = Draft()
        let (manager, lockfile) = manager(files: files)
        if let lockfile {
            draft.install = Found(value: installCommand(manager, files: files), source: String(localized: "found \(lockfile)"))
        }
        if files.contains(".env.example") {
            draft.envFromSource = Found(value: [".env"], source: String(localized: "found .env.example, so the project reads a .env"))
        }
        guard let text = packageJSON, let package = try? JSONDecoder().decode(Package.self, from: Data(text.utf8)) else { return draft }
        let scripts = package.scripts ?? [:]
        guard let name = ["dev", "start", "serve"].first(where: { scripts[$0] != nil }), let script = scripts[name] else { return draft }
        let base = manager.run(name)
        let found = String(localized: "found in package.json: scripts.\(name) = “\(script)”")
        // The framework, from the dev script (an AdonisJS app also lists vite).
        let words = script.lowercased()
        let framework: (name: String, port: PortStyle?, hmr: Bool?, why: String)? =
            if words.contains("ace serve") {
                ("AdonisJS", .env(["PORT": "{port}", "HOST": "127.0.0.1"]), words.contains("--hmr") ? true : (words.contains("--watch") ? false : nil),
                 found)
            } else if words.contains("next dev") {
                ("Next.js", .flags("-p $PORT -H 127.0.0.1"), true, found)
            } else if words.contains("react-scripts start") {
                ("Create React App", .env(["PORT": "{port}", "HOST": "127.0.0.1", "BROWSER": "none"]), true, found)
            } else if words.contains("nuxt") {
                ("Nuxt", .flags("--port $PORT --host 127.0.0.1"), true, found)
            } else if words.contains("astro") {
                ("Astro", .flags("--port $PORT --host 127.0.0.1"), true, found)
            } else if words.contains("webpack serve") || words.contains("webpack-dev-server") {
                ("webpack dev server", .flags("--port $PORT --host 127.0.0.1"), true, found)
            } else if words.contains("vite") {
                ("Vite", .flags("--port $PORT --strictPort --host 127.0.0.1"), true, found)
            } else {
                nil
            }
        draft.command = Found(value: base, source: found)
        guard let framework else { return draft }
        draft.framework = Found(value: framework.name, source: framework.why)
        if let port = framework.port {
            draft.port = Found(value: port, source: String(localized: "\(framework.name) takes its port this way"))
            if case let .flags(args) = port { draft.command = Found(value: base + manager.passing(args), source: found) }
        }
        if let hmr = framework.hmr {
            draft.hotReload = Found(value: hmr, source: hmr
                ? String(localized: "\(framework.name)'s dev server reloads changes")
                : String(localized: "\(framework.name) restarts on changes (--watch), without hot reload"))
        }
        draft.ready = Found(value: "/", source: String(localized: "\(framework.name) serves its home page at /"))
        return draft
    }

    /// The package manager, from the lockfile at the root.
    private static func manager(files: Set<String>) -> (Manager, String?) {
        if files.contains("pnpm-lock.yaml") { return (.pnpm, "pnpm-lock.yaml") }
        if files.contains("yarn.lock") { return (.yarn, "yarn.lock") }
        if files.contains("bun.lockb") { return (.bun, "bun.lockb") }
        if files.contains("bun.lock") { return (.bun, "bun.lock") }
        if files.contains("package-lock.json") { return (.npm, "package-lock.json") }
        return (.npm, nil)
    }

    private static func installCommand(_ manager: Manager, files: Set<String>) -> String {
        switch manager {
        case .npm: "npm ci --no-audit --no-fund"
        case .pnpm: "pnpm install --frozen-lockfile"
        case .yarn: files.contains(".yarnrc.yml") ? "yarn install --immutable" : "yarn install --frozen-lockfile"
        case .bun: "bun install --frozen-lockfile"
        }
    }

    /// The draft as darkmux's preview recipe (`schema_version` "1.0", the
    /// fields darkmux reads), once each value is confirmed. nil without a
    /// command.
    static func recipe(_ draft: Draft) -> [String: Any]? {
        guard let command = draft.command?.value, !command.isEmpty else { return nil }
        var recipe: [String: Any] = ["schema_version": "1.0", "command": command]
        switch draft.port?.value {
        case let .env(env)?: recipe["env"] = env
        case .flags?: recipe["env"] = ["PORT": "{port}"]
        case nil: break
        }
        if let ready = draft.ready?.value { recipe["ready"] = ["http": ready] }
        if let install = draft.install?.value { recipe["install"] = ["command": install, "unless_exists": "node_modules"] }
        if let files = draft.envFromSource?.value, !files.isEmpty { recipe["env_from_source"] = files }
        return recipe
    }
}
