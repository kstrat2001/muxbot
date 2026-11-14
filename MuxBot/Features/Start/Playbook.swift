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
    /// The questions you answer in words, in order: the name, what it's
    /// for, how it should feel.
    var questions: [String]
    /// Schema 3: questions you answer by picking one of its choices, each
    /// shown with its preview images when the registry has them.
    var choices: [PlaybookChoice] = []
    /// The bot's persona, with `{name}` for its name.
    var persona: String
    var skills: [BotSkill]
    /// `## First run`: lines with `{name}`, `{purpose}`, `{feel}` and, since
    /// schema 3, each choice's `{key}`.
    var firstRun: String? = nil
    /// The schema the file follows.
    var schema: Int = TemplateSchema.supported
    /// Schema 2: `page_file`, `pages`, `viewports` and `## Conventions`, the
    /// app's hints about the repo (darkmux's recipe holds none of them).
    var hints = RepoHints()
    /// Schema 3 `previews: desktop, phone`: the template's own pictures, in
    /// the registry, for its card. Optional.
    var previews: [TemplatePreview.Viewport] = []

    enum ParseError: Error, Equatable {
        case missing(String)
        case tooLarge
        case newerSchema(Int)
        case notASchema(String)
        case unknownKey(String, closest: String)
        case missingSection(String)
        /// Schema 3: a choice question that isn't written the way SCHEMA.md
        /// says (a `key:`, two or more `- id: Title.` lines, ids unique).
        case badChoice(String)

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
            case .badChoice(let question):
                String(localized: "This template's PLAYBOOK.md has a choice it can't read: “\(question)”.")
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
    func firstRunTask(name: String, purpose: String, feel: String, choices picked: [String: String] = [:]) -> String? {
        guard let firstRun else { return nil }
        let clean: (String) -> String = {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        }
        var answers = ["{name}": clean(name), "{purpose}": clean(purpose), "{feel}": clean(feel)]
        for choice in choices { answers["{\(choice.key)}"] = picked[choice.key] ?? choice.options.first?.id ?? "" }
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
        if let value = header["previews"] {
            guard schema >= 3 else { throw ParseError.unknownKey("previews", closest: TemplateSchema.closest(to: "previews", in: schemaOneKeys + hintKeys)) }
            guard let viewports = TemplatePreview.viewports(value) else { throw ParseError.missing("previews") }
            playbook.previews = viewports
        }
        playbook.hints = RepoHints(pageFile: header["page_file"].flatMap { $0.isEmpty ? nil : $0 },
                                   pages: list("pages"), viewports: list("viewports"))
        for (heading, body) in sections {
            if heading == "Questions", schema >= 3 {
                (playbook.questions, playbook.choices) = try questionsAndChoices(body)
            } else if heading == "Questions" {
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

    /// Schema 3's `## Questions`: a question is a `- ` bullet at the start of
    /// its line; one with indented lines under it is a choice: `key: <key>`
    /// names its answer (`{key}` in First run), and each indented
    /// `- <id>: <Title>. <what it fits>` is one choice.
    private static func questionsAndChoices(_ body: String) throws -> ([String], [PlaybookChoice]) {
        var items: [(text: String, key: String?, previews: [TemplatePreview.Viewport], options: [PlaybookChoice.Option])] = []
        for raw in body.components(separatedBy: "\n") where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indented = raw.first?.isWhitespace == true
            let bullet = line.hasPrefix("- ") || line.hasPrefix("* ")
            if !indented, bullet {
                items.append((String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces), nil, [], []))
            } else if indented, !items.isEmpty, line.hasPrefix("key:") {
                items[items.count - 1].key = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            } else if indented, !items.isEmpty, line.hasPrefix("previews:") {
                guard let viewports = TemplatePreview.viewports(String(line.dropFirst(9))) else { throw ParseError.badChoice(items[items.count - 1].text) }
                items[items.count - 1].previews = viewports
            } else if indented, !items.isEmpty, bullet {
                let text = line.dropFirst(2)
                guard let colon = text.firstIndex(of: ":") else { throw ParseError.badChoice(String(text)) }
                let id = text[..<colon].trimmingCharacters(in: .whitespaces)
                guard PlaybookChoice.isId(id) else { throw ParseError.badChoice(String(text)) }
                let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let stop = rest.range(of: ". ")
                let title = stop.map { String(rest[..<$0.lowerBound]) } ?? rest.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let detail = stop.map { rest[$0.upperBound...].trimmingCharacters(in: .whitespaces) } ?? ""
                guard !title.isEmpty else { throw ParseError.badChoice(String(text)) }
                items[items.count - 1].options.append(.init(id: id, title: title, detail: detail))
            }
        }
        var questions: [String] = []
        var choices: [PlaybookChoice] = []
        for item in items {
            if item.options.isEmpty, item.key == nil, item.previews.isEmpty { questions.append(item.text); continue }
            guard let key = item.key, PlaybookChoice.isId(key), !["name", "purpose", "feel"].contains(key),
                  !choices.contains(where: { $0.key == key }) else { throw ParseError.badChoice(item.text) }
            guard item.options.count >= 2, Set(item.options.map(\.id)).count == item.options.count else { throw ParseError.badChoice(item.text) }
            choices.append(PlaybookChoice(label: item.text, key: key, previews: item.previews, options: item.options))
        }
        return (questions, choices)
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
    private static let keys = schemaOneKeys + hintKeys + ["previews"]

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

/// Schema 3: a question you answer by picking one choice ("Pick a
/// design."). The answer is the choice's id, `{key}` in First run. When the
/// question asks for them, each choice's preview pictures live in the
/// registry repo (`TemplatePreview`), so a template's files never carry them.
struct PlaybookChoice: Equatable, Sendable {
    struct Option: Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        /// What it fits, in a sentence (may be empty).
        var detail: String
    }

    var label: String
    var key: String
    /// `previews: desktop, phone`: each choice has these pictures in the
    /// registry. Optional: without it the choices are chips.
    var previews: [TemplatePreview.Viewport] = []
    var options: [Option]

    /// Lowercase letters, digits and dashes, starting with a letter or digit.
    static func isId(_ s: String) -> Bool {
        let ok: (Character) -> Bool = { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        guard let first = s.first, ok(first) else { return false }
        return s.allSatisfy { ok($0) || $0 == "-" }
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
        if let example { return String(localized: "\(name): what exactly? For example, “\(example)”.") }
        return String(localized: "\(name): what exactly should I do?")
    }

    /// The first example ask from its "When:" line ("Make it dark green").
    var example: String? {
        let when = body.components(separatedBy: "\n").first { $0.lowercased().hasPrefix("when:") } ?? ""
        let quoted = when.split(separator: "\"", omittingEmptySubsequences: false)
        return quoted.count >= 3 && !quoted[1].isEmpty ? String(quoted[1]) : nil
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

extension Playbook.ParseError {
    /// The same, about a project's own PLAYBOOK.md (Work on a project I
    /// already have), not a template's.
    var projectMessage: String {
        switch self {
        case .newerSchema(let n):
            String(localized: "This project's PLAYBOOK.md needs a newer Mux Bot (it's schema \(n); this Mux Bot reads schema \(TemplateSchema.supported)).")
        case .missing("schema"):
            String(localized: "This project's PLAYBOOK.md doesn't say which schema it follows.")
        case .notASchema(let v):
            String(localized: "This project's PLAYBOOK.md has schema “\(v)”, which isn't a schema number.")
        case .missing(let key):
            String(localized: "This project's PLAYBOOK.md is missing “\(key)”.")
        case .unknownKey(let key, let closest):
            String(localized: "This project's PLAYBOOK.md has an unknown key “\(key)” (did you mean “\(closest)”?).")
        case .missingSection(let section):
            String(localized: "This project's PLAYBOOK.md is missing its “\(section)” section.")
        case .tooLarge:
            String(localized: "This project's PLAYBOOK.md is too large.")
        case .badChoice(let question):
            String(localized: "This project's PLAYBOOK.md has a choice it can't read: “\(question)”.")
        }
    }
}
