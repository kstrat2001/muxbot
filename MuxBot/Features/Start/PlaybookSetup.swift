import Foundation

/// A PLAYBOOK.md Mux Bot offers for a project that has none, on an Approve
/// card: schema 1, with the structure fixed in code and only the prose (the
/// persona, the project's conventions in each skill) drafted by the
/// on-device model from the README and your answers, all editable. On
/// Approve the exact file is written into your own checkout, uncommitted,
/// and goes into the bot's next pull request.
struct PlaybookSetup: Codable, Equatable, Sendable {
    static let path = "PLAYBOOK.md"

    var name: String
    /// What the project is, in your words (the start question).
    var purpose: String
    var persona: String
    var skills: [BotSkill]
    /// The on-device model wrote the persona and conventions: check them.
    var drafted: Bool
    /// Your checkout's folder name, for the card.
    var folderName: String

    /// The general playbook's persona and skills, for this project.
    @MainActor
    static func general(name: String, purpose: String, folderName: String) -> PlaybookSetup {
        let playbook = ExistingProject.general
        return PlaybookSetup(name: name, purpose: purpose, persona: playbook.persona(for: name),
                             skills: playbook.skills, drafted: false, folderName: folderName)
    }

    /// With the model's draft: its persona, and the project's conventions
    /// added to every skill as "Files and conventions".
    func withDraft(persona: String, conventions: String) -> PlaybookSetup {
        var copy = self
        let persona = persona.trimmingCharacters(in: .whitespacesAndNewlines)
        let conventions = conventions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !persona.isEmpty { copy.persona = persona }
        if !conventions.isEmpty {
            copy.skills = skills.map { skill in
                var s = skill
                s.body = s.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nFiles and conventions: " + conventions
                return s
            }
        }
        copy.drafted = !persona.isEmpty || !conventions.isEmpty
        return copy
    }

    /// The file, in Mux Bot's template schema 1.
    var markdown: String {
        let line: (String) -> String = { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        // A body line that starts a `##` section would split the file.
        let block: (String) -> String = { text in
            text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                .map { $0.hasPrefix("## ") || $0 == "##" ? "#" + $0 : $0 }
                .joined(separator: "\n")
        }
        let pitch = line(purpose).isEmpty ? String(localized: "Keep improving \(line(name)).") : line(purpose)
        var out = """
            # Playbook: \(line(name))

            schema: 2
            title: \(line(name))
            icon: \(ExistingProject.icon)
            pitch: \(pitch)
            crew: coder

            This file is the recipe Mux Bot reads for this project, in Mux Bot's template schema (schema 2): what it asks first, the bot's persona, and its skills (when each applies, what to do, the files and conventions, and when it's done).

            ## Questions

            - What should the bot be called?
            - What is this project, in a sentence?

            ## Persona

            \(block(persona))

            """
        for skill in skills where !line(skill.name).isEmpty {
            out += "\n## Skill: \(line(skill.name))\n\n\(block(skill.body))\n"
        }
        return out
    }

    var data: Data { Data(markdown.utf8) }

    /// The file as Mux Bot reads it: nil when it doesn't follow the schema
    /// (an emptied persona, every skill removed), so it can't be approved.
    var parsed: Playbook? { try? Playbook.parse(markdown) }
}
