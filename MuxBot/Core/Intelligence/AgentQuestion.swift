import Foundation

/// A crew member that stopped to ask: its numbered options, so each can be
/// answered with one tap (sent as a Tweak).
enum AgentQuestion {
    /// "1. …", "2) …", "**3.** …" lines, in order; empty when there are none.
    static func options(in notes: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: #"^\s*(?:\*\*)?\s*(\d{1,2})[.)](?:\*\*)?\s+(.+?)\s*$"#)
        var out: [String] = []
        for raw in notes.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard let m = pattern?.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
            let text = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: "**", with: "")
            if !text.isEmpty { out.append(String(text.prefix(160))) }
        }
        return out.count >= 2 ? out : []
    }
}

/// How a run's card shows itself.
enum RunCardState {
    /// A result a later run in the same thread replaced: shown as a quiet line.
    @MainActor
    static func isReplaced(_ run: BotRun) -> Bool {
        run.phase == .result && (run.bot?.runs ?? []).contains { $0.id != run.id && $0.createdAt > run.createdAt }
    }
}
