import Foundation

/// A link to a run's card in its bot's thread: `muxbot://run/<id>`.
enum RunLink {
    static let scheme = "muxbot"

    @MainActor static func url(for run: BotRun) -> URL { url(for: run.id) }
    static func url(for id: UUID) -> URL { URL(string: "\(scheme)://run/\(id.uuidString)")! }

    static func runId(from url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == "run" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

/// What the bots are doing and what waits on you, from the runs themselves
/// (never the model's guess): the chief of staff's answer to "what's
/// running?", "what needs me?" and "what's next?".
enum WorkStatus {
    /// Results that have waited this long for Keep or Discard get a nudge.
    static let nudgeAfter: TimeInterval = 24 * 3600

    static func isWorkQuestion(_ lower: String) -> Bool {
        let phrases = ["what's running", "whats running", "what is running", "anything running",
                       "what needs me", "needs my", "need me", "what's next", "whats next", "what is next",
                       "what's waiting", "anything waiting", "status", "what's going on", "whats going on",
                       "catch me up", "where are we"]
        return phrases.contains { lower.contains($0) }
    }

    /// "7 min", "3 h", "1 day", "4 days".
    static func span(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 3600 { return "\(max(1, Int(s / 60))) min" }
        if s < 86400 { return "\(Int(s / 3600)) h" }
        let d = Int(s / 86400)
        return d == 1 ? "1 day" : "\(d) days"
    }

    @MainActor
    private static func line(_ run: BotRun, _ detail: String?) -> String {
        "• \(run.botName): \(run.task)\(detail.map { ", \($0)" } ?? "") (\(RunLink.url(for: run).absoluteString))"
    }

    @MainActor
    static func summary(runs: [BotRun], now: Date = .now) -> String {
        let newest: (BotRun, BotRun) -> Bool = { $0.createdAt > $1.createdAt }
        var sections: [String] = []
        let running = runs.filter { $0.phase == .running }.sorted(by: newest)
        if !running.isEmpty {
            sections.append("Running:\n" + running.map { line($0, $0.startedAt.map { span(now.timeIntervalSince($0)) }) }.joined(separator: "\n"))
        }
        let proposed = runs.filter { $0.phase == .proposed }.sorted(by: newest)
        if !proposed.isEmpty {
            sections.append("Waiting for your Approve:\n" + proposed.map { line($0, nil) }.joined(separator: "\n"))
        }
        let results = runs.filter { $0.phase == .result }.sorted(by: newest)
        if !results.isEmpty {
            sections.append("Results to Keep or Discard:\n" + results.map { r in
                line(r, r.finishedAt.map { "waiting \(span(now.timeIntervalSince($0)))" })
            }.joined(separator: "\n"))
        }
        let kept = runs.filter { $0.phase == .kept }.sorted(by: newest)
        if !kept.isEmpty {
            sections.append("Kept, PR not decided:\n" + kept.map { line($0, $0.keptBranch) }.joined(separator: "\n"))
        }
        let failed = runs.filter { r in
            r.phase == .failed && (r.finishedAt.map { now.timeIntervalSince($0) < 86400 } ?? false)
        }.sorted(by: newest)
        if !failed.isEmpty {
            sections.append("Didn't finish:\n" + failed.map { line($0, nil) }.joined(separator: "\n"))
        }
        return sections.isEmpty ? "Nothing is running and nothing waits on you." : sections.joined(separator: "\n\n")
    }

    /// Results that have waited too long for a decision.
    @MainActor
    static func nudges(runs: [BotRun], now: Date = .now) -> [String] {
        runs.filter { $0.phase == .result }
            .compactMap { r in
                guard let done = r.finishedAt, now.timeIntervalSince(done) >= nudgeAfter else { return nil }
                return "\(r.botName)'s result for “\(r.task)” has waited \(span(now.timeIntervalSince(done))) for Keep or Discard."
            }
    }
}
