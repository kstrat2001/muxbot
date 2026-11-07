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

    static func classify(error raw: String, reason: String?) -> RunEnd {
        let lower = (raw + " " + (reason ?? "")).lowercased()
        if reason == "cancelled" || ["cancelled", "sigterm", "sigkill", "exit 143", "signal 15", "signal 9", "killed"].contains(where: { lower.contains($0) }) {
            return .stopped
        }
        let lines = withoutPlumbing(raw).split(separator: "\n").map(String.init)
        let line = lines.last { $0.lowercased().hasPrefix("error") } ?? lines.last ?? reason ?? "darkmux didn't say why"
        var short = line
        if let colon = short.range(of: ":"), short.lowercased().hasPrefix("error") { short = String(short[colon.upperBound...]) }
        return .failed(String(short.trimmingCharacters(in: .whitespaces).prefix(140)))
    }

    /// The bot's own short line when the on-device model can't write one.
    static func fallbackSummary(report: String, files: [String]) -> String {
        let text = plain(report)
        let first = text.split(whereSeparator: { ".\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count > 12 } ?? ""
        let cleaned = first.replacingOccurrences(of: #"^[A-Z][a-z]+:\s*"#, with: "", options: .regularExpression)
        let names = files.map { ($0 as NSString).lastPathComponent }
        var line = "Done." + (cleaned.isEmpty ? "" : " " + String(cleaned.prefix(200)) + ".")
        if !names.isEmpty { line += " Changed \(names.joined(separator: ", "))." }
        return line
    }
}
