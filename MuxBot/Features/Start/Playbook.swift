import Foundation

/// A template's PLAYBOOK.md: the recipe Mux Bot follows to make a bot for a
/// project. Plain Markdown, readable on GitHub: a header of `key: value`
/// lines (schema, title, icon, pitch, animal, colors, crew), then
/// `## Questions` (what Mux Bot asks first), `## Persona`, one
/// `## Skill: <name>` section per skill, and optionally `## First run` (the
/// new bot's first dispatch, from your answers), in the template schema
/// (kstrat2001/muxbot-templates SCHEMA.md). Parsed by hand. A missing or
/// newer schema, a missing required key or section, or an unknown header
/// key is refused by name; an unknown `##` section is skipped.
struct Playbook: Equatable, Sendable {
    var title: String
    var icon: String
    var pitch: String
    /// `animal` and `colors`: still read, so older playbooks parse, but they
    /// no longer set a new bot's look (each bot gets a fresh one,
    /// `BotLook.fresh`).
    var animal: BotAnimal?
    var bodyHex: String?
    var eyeHex: String?
    var crew: [CrewRole]
    var questions: [String]
    /// The bot's persona, with `{name}` for its name.
    var persona: String
    var skills: [BotSkill]
    /// `## First run`: lines with `{name}`, `{purpose}` and `{feel}`.
    var firstRun: String? = nil
    /// The schema the file follows.
    var schema: Int = TemplateSchema.supported
    /// Schema 2: `page_file`, `pages`, `viewports` and `## Conventions`, the
    /// app's hints about the repo (darkmux's recipe holds none of them).
    var hints = RepoHints()

    enum ParseError: Error, Equatable {
        case missing(String)
        case tooLarge
        case newerSchema(Int)
        case notASchema(String)
        case unknownKey(String, closest: String)
        case missingSection(String)

        /// What the start screen says about a template it can't use.
        var message: String {
            switch self {
            case .newerSchema(let n):
                String(localized: "This template needs a newer Mux Bot (its PLAYBOOK.md is schema \(n); this Mux Bot reads schema \(TemplateSchema.supported)).")
            case .missing("schema"):
                String(localized: "This template's PLAYBOOK.md doesn't say which schema it follows.")
            case .notASchema(let v):
                String(localized: "This template's PLAYBOOK.md has schema “\(v)”, which isn't a schema number.")
            case .missing(let key):
                String(localized: "This template's PLAYBOOK.md is missing “\(key)”.")
            case .unknownKey(let key, let closest):
                String(localized: "This template's PLAYBOOK.md has an unknown key “\(key)” (did you mean “\(closest)”?).")
            case .missingSection(let section):
                String(localized: "This template's PLAYBOOK.md is missing its “\(section)” section.")
            case .tooLarge:
                String(localized: "This template's PLAYBOOK.md is too large.")
            }
        }
    }

    static let maxBytes = 64 * 1024

    func persona(for name: String) -> String {
        persona.replacingOccurrences(of: "{name}", with: name)
    }

    /// The first run's task from your answers: each line of `## First run`
    /// with its placeholders filled in, and a line whose answer is blank left
    /// out. nil when there's no section or nothing but blanks is left.
    func firstRunTask(name: String, purpose: String, feel: String) -> String? {
        guard let firstRun else { return nil }
        let clean: (String) -> String = {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        }
        let answers = ["{name}": clean(name), "{purpose}": clean(purpose), "{feel}": clean(feel)]
        var lines: [String] = []
        var usedAnAnswer = false
        for line in firstRun.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            let used = answers.filter { line.contains($0.key) }
            if used.contains(where: { $0.value.isEmpty }) { continue }
            if used.keys.contains(where: { $0 != "{name}" }) { usedAnAnswer = true }
            lines.append(used.reduce(line) { $0.replacingOccurrences(of: $1.key, with: $1.value) })
        }
        let mentionsAnswers = answers.keys.contains { $0 != "{name}" && firstRun.contains($0) }
        guard !lines.isEmpty, usedAnAnswer || !mentionsAnswers else { return nil }
        return lines.joined(separator: " ")
    }

    static func parse(_ text: String) throws -> Playbook {
        guard text.utf8.count <= maxBytes else { throw ParseError.tooLarge }
        let (header, sections) = try split(text)
        try TemplateSchema.check(header["schema"], missing: ParseError.missing("schema"),
                                 newer: ParseError.newerSchema, notANumber: ParseError.notASchema)
        for key in ["title", "icon", "pitch"] where (header[key] ?? "").isEmpty { throw ParseError.missing(key) }
        let title = header["title"] ?? ""
        let colors = (header["colors"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let hex = colors.map { isHex($0) ? $0 : nil }
        let crew = (header["crew"] ?? "").split(separator: ",")
            .compactMap { CrewRole(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        let schema = Int(header["schema"] ?? "") ?? TemplateSchema.supported
        // The hint keys arrived with schema 2.
        if schema < 2, let key = hintKeys.first(where: { header[$0] != nil }) {
            throw ParseError.unknownKey(key, closest: TemplateSchema.closest(to: key, in: schemaOneKeys))
        }
        let list: (String) -> [String]? = { key in
            header[key].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
        var playbook = Playbook(title: title, icon: header["icon"] ?? "", pitch: header["pitch"] ?? "",
                                animal: header["animal"].flatMap(BotAnimal.init(rawValue:)),
                                bodyHex: hex.first ?? nil, eyeHex: hex.dropFirst().first ?? nil,
                                crew: crew.isEmpty ? [.coder] : crew, questions: [], persona: "", skills: [])
        playbook.schema = schema
        playbook.hints = RepoHints(pageFile: header["page_file"].flatMap { $0.isEmpty ? nil : $0 },
                                   pages: list("pages"), viewports: list("viewports"))
        for (heading, body) in sections {
            if heading == "Questions" {
                playbook.questions = body.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
                    .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            } else if heading == "Persona" {
                playbook.persona = body
            } else if heading == "Conventions", schema >= 2 {
                playbook.hints.conventions = body.isEmpty ? nil : body
            } else if heading == "First run" {
                playbook.firstRun = body.isEmpty ? nil : body
            } else if heading.hasPrefix("Skill:") {
                let name = heading.dropFirst("Skill:".count).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !body.isEmpty { playbook.skills.append(BotSkill(name: name, body: body)) }
            }
        }
        let headings = sections.map(\.0)
        if !headings.contains("Questions") || playbook.questions.isEmpty { throw ParseError.missingSection("Questions") }
        if playbook.persona.isEmpty { throw ParseError.missingSection("Persona") }
        if playbook.skills.isEmpty { throw ParseError.missingSection("Skill") }
        return playbook
    }

    /// The `key: value` lines before the first `##` section, and each
    /// section's heading and trimmed text.
    private static func split(_ text: String) throws -> ([String: String], [(String, String)]) {
        var header: [String: String] = [:]
        var sections: [(String, [String])] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                sections.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), []))
            } else if sections.isEmpty {
                if let (key, value) = try keyValue(line), header[key] == nil { header[key] = value }
            } else {
                sections[sections.count - 1].1.append(line)
            }
        }
        return (header, sections.map { ($0.0, $0.1.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) })
    }

    private static let schemaOneKeys = ["schema", "title", "icon", "pitch", "animal", "colors", "crew"]
    private static let hintKeys = ["page_file", "pages", "viewports"]
    private static let keys = schemaOneKeys + hintKeys

    /// A header key is a lowercase word at the start of the line, a colon,
    /// then the value; other prose is ignored. An unknown key is refused.
    private static func keyValue(_ line: String) throws -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        guard !key.isEmpty, key.allSatisfy({ $0.isLowercase || $0 == "_" }) else { return nil }
        guard keys.contains(key) else { throw ParseError.unknownKey(key, closest: TemplateSchema.closest(to: key, in: keys)) }
        return (key, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    private static func isHex(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy(\.isHexDigit)
    }
}

/// A playbook question, with the examples in its trailing parentheses
/// ("(For example: calm and minimal, bold and colorful.)") as suggestions
/// you can tap.
struct PlaybookQuestion: Equatable, Sendable {
    var label: String
    var suggestions: [String]

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else {
            label = trimmed
            suggestions = []
            return
        }
        var inside = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        for prefix in ["For example:", "for example:", "e.g.", "Like:"] where inside.hasPrefix(prefix) {
            inside = String(inside.dropFirst(prefix.count))
        }
        let items = inside.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // "a, b, or c": the last item without its "or".
            .map { item in ["or ", "and "].first { item.lowercased().hasPrefix($0) }.map { String(item.dropFirst($0.count)) } ?? item }
            .filter { !$0.isEmpty }
        guard items.count >= 2 else {
            label = trimmed
            suggestions = []
            return
        }
        label = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        // "A portfolio, a small business": the same case for each.
        suggestions = items.map { $0.prefix(1).lowercased() + $0.dropFirst() }
    }

    /// A tapped suggestion fills an empty answer, or is added to it once.
    static func adding(_ suggestion: String, to text: String) -> String {
        let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty { return suggestion }
        if current.localizedCaseInsensitiveContains(suggestion) { return current }
        return current + ", " + suggestion
    }
}

/// A skill a bot has: when it applies, what to do, the files and
/// conventions, and when it's done. Copied into the bot when it's made.
struct BotSkill: Codable, Equatable, Sendable {
    var name: String
    var body: String

    /// What the bot asks when the skill is picked by name: what exactly,
    /// with the first example ask from its "When:" line.
    var question: String {
        let when = body.components(separatedBy: "\n").first { $0.lowercased().hasPrefix("when:") } ?? ""
        let quoted = when.split(separator: "\"", omittingEmptySubsequences: false)
        if quoted.count >= 3, !quoted[1].isEmpty {
            return String(localized: "\(name): what exactly? For example, “\(String(quoted[1]))”.")
        }
        return String(localized: "\(name): what exactly should I do?")
    }

    /// The skills that fit a request, best first (at most two), searched on
    /// device like the help. A skill only needs some of the request's words:
    /// it adds notes to a brief, it never answers on its own.
    static func relevant(_ skills: [BotSkill], to request: String, limit: Int = 2) -> [BotSkill] {
        guard !skills.isEmpty else { return [] }
        let article = HelpArticle(id: "skills", markdown: "# Skills\n\n" + skills.map { "## \($0.name)\n\n\($0.body)" }.joined(separator: "\n\n"))
        let hits = HelpLibrary(articles: [article]).search(request, limit: limit, minCoverage: 0.25)
        return hits.compactMap { hit in skills.first { $0.name == hit.section } }
    }
}
