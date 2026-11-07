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
    /// After an Undo: "Undone". (Older builds' kept runs: "Committed to …".)
    @MainActor
    static func collapsedLine(_ run: BotRun) -> String? {
        switch run.phase {
        case .discarded: "Undone"
        case .kept, .done, .prOpened: run.keptBranch.map { "Committed to \($0)" }
        default: nil
        }
    }

    @MainActor
    static func isReplaced(_ run: BotRun) -> Bool {
        run.phase == .result && (run.bot?.runs ?? []).contains { $0.id != run.id && $0.createdAt > run.createdAt }
    }
}

/// The pinned "needs you" banner at the top of a bot's thread: only runs
/// waiting for Approve and runs that stopped with a question. Dismissing it
/// only hides it (they stay in Activity > Needs you); a new item brings it back.
enum NeedsYouBanner {
    @MainActor
    static func items(_ runs: [BotRun], dismissed: Set<UUID>) -> [BotRun] {
        let waiting = runs.filter(\.needsYou).sorted { $0.createdAt < $1.createdAt }
        let fresh = waiting.filter { !dismissed.contains($0.id) }
        return fresh.isEmpty ? [] : fresh
    }
}
