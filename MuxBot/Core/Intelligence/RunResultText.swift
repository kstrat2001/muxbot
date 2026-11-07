import Foundation

/// How a darkmux run ended, in words a person reads.
enum RunEnd: Equatable, Sendable {
    case stopped
    case failed(String)
}

/// Turns darkmux's raw run output into what the chat shows: a short,
/// friendly line; never plumbing (runtime images, liveness, out-dirs).
enum RunResultText {
    static let prUnavailable = "I can't open pull requests from the app yet: that needs GitHub sign-in, which isn't here. I can pass it to Mux Bot, or you can open one from the work copy."

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
