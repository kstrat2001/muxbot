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
    /// Undo reverts a run's commit: only a result that has one.
    @MainActor static func canUndo(_ run: BotRun) -> Bool { run.phase == .result && run.keptCommit != nil }

    /// A result whose changes darkmux couldn't commit: why (or a plain
    /// line when it didn't say). nil when it was committed or changed nothing.
    @MainActor static func checkpointProblem(_ run: BotRun) -> String? {
        guard run.phase == .result, !run.changedFiles.isEmpty, run.keptCommit == nil else { return nil }
        return run.details ?? "darkmux didn't commit these changes."
    }

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

    /// Close (Done): a result with nothing to undo that's still open: a
    /// question, changes darkmux couldn't commit, or a read-only crew's
    /// answer (a review, research).
    @MainActor static func canClose(_ run: BotRun) -> Bool {
        run.phase == .result && !canUndo(run) && (run.needsYou || !run.crew.changesFiles)
    }

    /// Replaced only by a later run that actually ran (not one waiting for
    /// Approve or canceled before it started), and never while it still
    /// needs you.
    @MainActor
    static func isReplaced(_ run: BotRun) -> Bool {
        guard run.phase == .result, !run.needsYou else { return false }
        // Only a later run that got as far as a result (or changed files)
        // replaces it; one that failed, was stopped or was undone never
        // hides this result or its Undo.
        let reachedResult: [RunPhase] = [.result, .kept, .done, .prOpened]
        return (run.bot?.runs ?? []).contains { later in
            later.id != run.id && later.createdAt > run.createdAt
                && ![RunPhase.failed, .canceled, .discarded].contains(later.phase)
                && (reachedResult.contains(later.phase) || !later.changedFiles.isEmpty)
        }
    }
}

