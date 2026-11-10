import Foundation

/// How a darkmux run ended, in words a person reads.
enum RunEnd: Equatable, Sendable {
    case stopped
    case failed(String)
}

/// Turns darkmux's raw run output into what the chat shows: a short,
/// friendly line; never plumbing (runtime images, liveness, out-dirs).
enum RunResultText {
    /// No GitHub sign-in yet, so the app can't push or open a PR itself.
    static func prUnavailable(branch: String?) -> String {
        guard let branch else {
            return "I can't open pull requests from the app yet: that needs GitHub sign-in, which isn't here. I can pass it to Mux Bot."
        }
        return "I can't open pull requests from the app yet (no GitHub sign-in). The change is committed on \(branch) on this Mac: push that branch and open a PR on GitHub, or pass it to Mux Bot."
    }

    /// darkmux refusing an Undo, in plain words: a later run that changed
    /// the same files is named by its task.
    @MainActor
    static func undoRefusal(_ error: String, runs: [BotRun]) -> String {
        if let range = error.range(of: #"run (w-[0-9A-Za-z]+) changed the same files later"#, options: .regularExpression) {
            let id = error[range].split(separator: " ")[1]
            let task = runs.first { $0.darkmuxWorkId == String(id) }?.task ?? "A later run"
            return "“\(task)” changed the same files later. Undo that first."
        }
        return "Couldn't undo it: \(error)\(error.hasSuffix(".") ? "" : ".")"
    }

    /// What Keep did: "Committed pricing.tsx to mux/x (abc1234)."
    static func kept(files: [String], branch: String, commit: String) -> String {
        let what = files.count == 1 ? ((files[0] as NSString).lastPathComponent) : "\(files.count) files"
        return "Committed \(what) to \(branch) (\(commit))."
    }

    /// What Discard did: "Put back README.md. Removed new.txt."
    static func discarded(restored: [String], removed: [String]) -> String {
        func list(_ files: [String]) -> String {
            files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) files"
        }
        var parts: [String] = []
        if !restored.isEmpty { parts.append("Put back \(list(restored)).") }
        if !removed.isEmpty { parts.append("Removed \(list(removed)).") }
        return parts.isEmpty ? "Nothing had changed." : parts.joined(separator: " ")
    }

    /// Markdown to plain text: no **, `, _ or links syntax.
    static func plain(_ markdown: String) -> String {
        let attributed = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        return (attributed.map { String($0.characters) } ?? markdown).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops darkmux's own notices from a log.
    static func withoutPlumbing(_ raw: String) -> String {
        let noise = ["[darkmux-liveness]", "darkmux dispatch:", "runtime image", "darkmux-runtime", "git unavailable", "darkmux-out", "credential-read"]
        return raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !noise.contains { line.localizedCaseInsensitiveContains($0) } }
            .joined(separator: "\n")
    }

    /// darkmux couldn't read a run's changes (`changes_error`): never
    /// "changed nothing".
    static let changesUnreadable = String(localized: "darkmux couldn't read what changed")

    /// darkmux answered 404 for a run it was running: it restarted, or it
    /// ended long ago. Never "Stopped.": nobody stopped it.
    static let lostTrack = String(localized: "darkmux restarted and lost track of this run. Check the project before running it again.")
    /// Approved, but the app quit before darkmux had it.
    static let quitBeforeStart = String(localized: "Mux Bot quit before darkmux started it.")

    /// Why a run failed, in plain words, from darkmux's `code` (client_wire
    /// `Error.code`); darkmux's own text only when the code says nothing more.
    static func failure(code: String?, error: String, reason: String?) -> String {
        switch code {
        case "busy": String(localized: "The model was busy with another run. Run it again in a moment.")
        case "wont_fit": String(localized: "The model doesn't fit on this Mac. Pick a smaller one in Settings › Models.")
        case "model_start_failed": String(localized: "The model wouldn't start.")
        case "model_stop_failed": String(localized: "darkmux couldn't free the model for this run.")
        case "port_in_use": String(localized: "Another program is using the model's port.")
        case "engine_unavailable": String(localized: "The model's server isn't running.")
        case "engine_in_use": String(localized: "The model's server is busy with something else.")
        default:
            switch classify(error: error, reason: reason) {
            case let .failed(why): why
            case .stopped: String(localized: "darkmux stopped it.")
            }
        }
    }

    /// Only darkmux's own "cancelled" is a stop; any error is a failure,
    /// whatever words it uses (a killed model server is still a failure).
    static func classify(error raw: String, reason: String?) -> RunEnd {
        if reason == "cancelled" || raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cancelled" { return .stopped }
        let lines = withoutPlumbing(raw).split(separator: "\n").map(String.init)
        let line = lines.last { $0.lowercased().hasPrefix("error") } ?? lines.last ?? reason ?? "darkmux didn't say why"
        var short = line
        if let colon = short.range(of: ":"), short.lowercased().hasPrefix("error") { short = String(short[colon.upperBound...]) }
        return .failed(String(short.trimmingCharacters(in: .whitespaces).prefix(140)))
    }

    /// "Coder said it changed inertia/css/app.css, but no files changed.":
    /// a run's text claims an edit while darkmux saw no changed files. nil
    /// when files changed or nothing claims one.
    static func unbackedClaim(in texts: [String], crew: String, changedFiles: [String]) -> String? {
        guard changedFiles.isEmpty else { return nil }
        let verbs = #"\b(added|changed|edited|updated|modified|created|wrote|rewrote|fixed|replaced|removed|inserted|adjusted)\b"#
        let negations = ["didn't", "did not", "no files", "not ", "nothing", "without", "stopped", "couldn't", "could not", "won't", "would "]
        let file = #"[\w./-]+\.(css|scss|sass|less|tsx?|jsx?|mjs|swift|rs|py|html?|json|md|ya?ml|go|rb|vue|svelte|edge|toml)\b"#
        for text in texts {
            let sentences = plain(text).components(separatedBy: CharacterSet(charactersIn: "\n")).flatMap { $0.components(separatedBy: ". ") }
            for sentence in sentences {
                let lower = sentence.lowercased()
                guard let verb = lower.range(of: verbs, options: .regularExpression),
                      !negations.contains(where: { lower[..<verb.lowerBound].contains($0) }) else { continue }
                let named = sentence.range(of: file, options: .regularExpression).map { String(sentence[$0]) }
                return "\(crew) said it changed \(named ?? "the code"), but no files changed."
            }
        }
        return nil
    }

    /// The bot's own short line when the on-device model can't write one.
    static func fallbackSummary(report: String, files: [String]) -> String {
        let text = plain(report)
        let first = text.split(whereSeparator: { ".\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count > 12 } ?? ""
        let cleaned = first.replacingOccurrences(of: #"^[A-Z][a-z]+:\s*"#, with: "", options: .regularExpression)
        let names = files.map { ($0 as NSString).lastPathComponent }
        var line = (names.isEmpty ? "Changed nothing." : "Done.") + (cleaned.isEmpty ? "" : " " + String(cleaned.prefix(200)) + ".")
        if !names.isEmpty { line += " Changed \(names.joined(separator: ", "))." }
        return line
    }
}
