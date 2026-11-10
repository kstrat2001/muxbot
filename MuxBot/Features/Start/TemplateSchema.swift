import Foundation

/// The template schema (kstrat2001/muxbot-templates SCHEMA.md): one version
/// number for templates.json and PLAYBOOK.md. Since schema 2 a template's
/// .darkmux/preview.json is darkmux's own recipe (`schema_version` "1.0",
/// darkmux's keys only) and the app's hints live in PLAYBOOK.md; schema 1
/// templates (hints in preview.json, `"schema": 1`) still read. Schema 3
/// adds choice questions to PLAYBOOK.md and makes preview images standard:
/// every template has a desktop and a phone picture, and so does each
/// choice, in the registry repo (`TemplatePreview`). An
/// added optional key keeps the number; a new required key, or a renamed
/// or removed one, is the next. Mux Bot refuses a missing schema, or one
/// newer than it reads, by name, and never guesses.
enum TemplateSchema {
    static let supported = 3

    /// Checks a file's schema value: present, a number, and not newer.
    static func check<E: Error>(_ value: String?, missing: E, newer: (Int) -> E, notANumber: (String) -> E) throws {
        guard let value, !value.isEmpty else { throw missing }
        guard let n = Int(value) else { throw notANumber(value) }
        if n > supported { throw newer(n) }
        if n < 1 { throw notANumber(value) }
    }

    /// The known key nearest to an unknown one, for "did you mean".
    static func closest(to key: String, in known: [String]) -> String {
        known.min { distance(key, $0) < distance(key, $1) } ?? ""
    }

    /// Edit distance between two keys.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var d = (0...a.count).map { i in [i] + Array(repeating: 0, count: b.count) }
        for j in 0...b.count { d[0][j] = j }
        for i in stride(from: 1, through: a.count, by: 1) {
            for j in stride(from: 1, through: b.count, by: 1) {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
        }
        return d[a.count][b.count]
    }

    enum Problem: Error, Equatable {
        case missingSchema(file: String)
        case newerSchema(file: String, Int)
        case notASchema(file: String, String)
        case unknownKey(file: String, key: String, closest: String)
        case invalid(file: String, key: String, why: String)

        var message: String {
            switch self {
            case let .missingSchema(file):
                String(localized: "This template's \(file) doesn't say which schema it follows.")
            case let .newerSchema(file, n):
                String(localized: "This template needs a newer Mux Bot (its \(file) is schema \(n); this Mux Bot reads schema \(TemplateSchema.supported)).")
            case let .notASchema(file, v):
                String(localized: "This template's \(file) has schema “\(v)”, which isn't a schema number.")
            case let .unknownKey(file, key, closest):
                String(localized: "This template's \(file) has an unknown key “\(key)” (did you mean “\(closest)”?).")
            case let .invalid(file, key, why):
                String(localized: "This template's \(file) has a problem at “\(key)”: \(why)")
            }
        }
    }

    // MARK: .darkmux/preview.json

    static let previewKeys = ["schema", "command", "env", "ready", "install", "env_from_source",
                              "conventions", "page_file", "pages", "viewports"]
    /// darkmux's recipe (its `client_preview` reader): `schema_version` and
    /// these keys only, an unknown one refused. A template has no checkout
    /// to copy files from, so no `env_from_source`.
    static let recipeVersion = "1.0"
    static let recipeKeys = ["schema_version", "command", "env", "ready", "install"]

    /// A template's preview recipe: darkmux's own (schema 2), or the schema 1
    /// file with the app's hints in it. `darkmuxShape` requires the first.
    static func checkPreview(_ data: Data, darkmuxShape: Bool = false) throws {
        let file = ".darkmux/preview.json"
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Problem.invalid(file: file, key: "(file)", why: String(localized: "it isn't a JSON object."))
        }
        if object["schema_version"] != nil || darkmuxShape {
            try checkRecipe(object, file: file)
            return
        }
        for key in object.keys.sorted() where !previewKeys.contains(key) {
            throw Problem.unknownKey(file: file, key: key, closest: closest(to: key, in: previewKeys))
        }
        let schema: String? = switch object["schema"] {
        case let n as Int: String(n)
        case let s as String: s
        case nil: nil
        default: "?"
        }
        try check(schema, missing: Problem.missingSchema(file: file),
                  newer: { Problem.newerSchema(file: file, $0) }, notANumber: { Problem.notASchema(file: file, $0) })
        if schema == "2" {
            throw Problem.invalid(file: file, key: "schema", why: String(localized: "a schema 2 template's preview.json is darkmux's recipe: write \u{201C}schema_version\u{201D}: \u{201C}\(recipeVersion)\u{201D} and keep the app's hints in PLAYBOOK.md."))
        }
        guard let command = object["command"] as? String, !command.isEmpty else {
            throw Problem.invalid(file: file, key: "command", why: String(localized: "it needs the command that starts the preview."))
        }
    }

    /// darkmux's recipe, checked the way darkmux checks it.
    private static func checkRecipe(_ object: [String: Any], file: String) throws {
        if object["env_from_source"] != nil {
            throw Problem.invalid(file: file, key: "env_from_source", why: String(localized: "a template has no checkout to copy files from."))
        }
        for key in object.keys.sorted() where !recipeKeys.contains(key) {
            throw Problem.unknownKey(file: file, key: key, closest: closest(to: key, in: recipeKeys))
        }
        guard object["schema_version"] as? String == recipeVersion else {
            throw Problem.invalid(file: file, key: "schema_version", why: String(localized: "darkmux reads \u{201C}\(recipeVersion)\u{201D}."))
        }
        guard let command = object["command"] as? String, !command.isEmpty else {
            throw Problem.invalid(file: file, key: "command", why: String(localized: "it needs the command that starts the preview."))
        }
    }
}
