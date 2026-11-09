import Foundation

/// A template's PLAYBOOK.md: the recipe Mux Bot follows to make a bot for a
/// project. Plain Markdown, readable on GitHub: a header of `key: value`
/// lines (title, icon, pitch, animal, colors, crew), then `## Questions`
/// (what Mux Bot asks first), `## Persona`, and one `## Skill: <name>`
/// section per skill. Parsed by hand; an unknown key or section is skipped.
struct Playbook: Equatable, Sendable {
    var title: String
    var icon: String
    var pitch: String
    var animal: BotAnimal?
    var bodyHex: String?
    var eyeHex: String?
    var crew: [CrewRole]
    var questions: [String]
    /// The bot's persona, with `{name}` for its name.
    var persona: String
    var skills: [BotSkill]

    enum ParseError: Error, Equatable {
        case missing(String)
        case tooLarge
    }

    static let maxBytes = 64 * 1024

    func persona(for name: String) -> String {
        persona.replacingOccurrences(of: "{name}", with: name)
    }

    static func parse(_ text: String) throws -> Playbook {
        guard text.utf8.count <= maxBytes else { throw ParseError.tooLarge }
        let (header, sections) = split(text)
        guard let title = header["title"], !title.isEmpty else { throw ParseError.missing("title") }
        let colors = (header["colors"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let hex = colors.map { isHex($0) ? $0 : nil }
        let crew = (header["crew"] ?? "").split(separator: ",")
            .compactMap { CrewRole(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        var playbook = Playbook(title: title, icon: header["icon"] ?? "sparkles", pitch: header["pitch"] ?? "",
                                animal: header["animal"].flatMap(BotAnimal.init(rawValue:)),
                                bodyHex: hex.first ?? nil, eyeHex: hex.dropFirst().first ?? nil,
                                crew: crew.isEmpty ? [.coder] : crew, questions: [], persona: "", skills: [])
        for (heading, body) in sections {
            if heading == "Questions" {
                playbook.questions = body.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
                    .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            } else if heading == "Persona" {
                playbook.persona = body
            } else if heading.hasPrefix("Skill:") {
                let name = heading.dropFirst("Skill:".count).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !body.isEmpty { playbook.skills.append(BotSkill(name: name, body: body)) }
            }
        }
        return playbook
    }

    /// The `key: value` lines before the first `##` section, and each
    /// section's heading and trimmed text.
    private static func split(_ text: String) -> ([String: String], [(String, String)]) {
        var header: [String: String] = [:]
        var sections: [(String, [String])] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                sections.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), []))
            } else if sections.isEmpty {
                if let (key, value) = keyValue(line), header[key] == nil { header[key] = value }
            } else {
                sections[sections.count - 1].1.append(line)
            }
        }
        return (header, sections.map { ($0.0, $0.1.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) })
    }

    private static let keys: Set<String> = ["title", "icon", "pitch", "animal", "colors", "crew"]

    private static func keyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard keys.contains(key) else { return nil }
        return (key, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    private static func isHex(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy(\.isHexDigit)
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
