import Foundation

/// The template schema (kstrat2001/muxbot-templates SCHEMA.md): one version
/// number for templates.json, PLAYBOOK.md and .darkmux/preview.json. An
/// added optional key keeps the number; a new required key, or a renamed
/// or removed one, is the next. Mux Bot refuses a missing schema, or one
/// newer than it reads, by name, and never guesses.
enum TemplateSchema {
    static let supported = 1

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

    /// A template's preview recipe, checked against the schema: its schema
    /// number, a command, and no key the schema doesn't name.
    static func checkPreview(_ data: Data) throws {
        let file = ".darkmux/preview.json"
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Problem.invalid(file: file, key: "(file)", why: String(localized: "it isn't a JSON object."))
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
        guard let command = object["command"] as? String, !command.isEmpty else {
            throw Problem.invalid(file: file, key: "command", why: String(localized: "it needs the command that starts the preview."))
        }
    }
}
