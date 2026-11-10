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
    /// A later run (named by darkmux's work id or its commit) that changed
    /// the same files is named by its task; anything else is one plain
    /// sentence (darkmux's words go behind Show details).
    @MainActor
    static func undoRefusal(_ error: String, runs: [BotRun]) -> String {
        var later: BotRun?
        var named = false
        if let range = error.range(of: #"run (w-[0-9A-Za-z]+) changed the same files later"#, options: .regularExpression) {
            named = true
            let id = String(error[range].split(separator: " ")[1])
            later = runs.first { $0.darkmuxWorkId == id }
        } else if let range = error.range(of: #"commit ([0-9a-f]{7,40}) changed the same files later"#, options: .regularExpression) {
            named = true
            let sha = String(error[range].split(separator: " ")[1])
            later = runs.first { ($0.keptCommit ?? "").hasPrefix(sha) || sha.hasPrefix($0.keptCommit ?? "-") }
        }
        if named {
            guard let later else { return String(localized: "A later run changed the same files. Undo the later run first.") }
            return String(localized: "“\(later.task)” changed the same files later. Undo that run first.")
        }
        return String(localized: "darkmux couldn't undo it. Show details has what it reported.")
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
    /// darkmux answered 404 for a run submitted under an earlier pairing.
    static let earlierPairing = String(localized: "This run is from an earlier pairing with darkmux, so this app can't follow it anymore. If it's still going, stop it on the Mac with darkmux.")
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
            // darkmux's own lines are in the run's details (Show details),
            // never the headline.
            switch classify(error: error, reason: reason) {
            case .failed: String(localized: "darkmux ran into a problem running it. Show details has what it reported.")
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

/// darkmux's errors in one plain sentence each, by status (and `code`);
/// its own words are the details, behind Show details.
enum DarkmuxPlain {
    static func sentence(_ error: any Error) -> String {
        if let url = error as? URLError {
            return [.cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost, .notConnectedToInternet].contains(url.code)
                ? String(localized: "darkmux isn't answering on this Mac.")
                : String(localized: "Mux Bot couldn't reach darkmux.")
        }
        // Not darkmux's answer (the app's own error): its own words.
        guard let client = error as? DarkmuxClient.ClientError else { return error.localizedDescription }
        // darkmux's coded refusals first: their status alone means something else.
        switch client.code {
        case "no_own_branch":
            return String(localized: "This work copy isn't on its own Mux Bot branch yet. Start a run and darkmux moves it there, then try again.")
        case "branch_failed":
            return String(localized: "darkmux couldn't make this bot's branch in the work copy. Show details has git's reason.")
        default: break
        }
        switch client.status {
        case 401: return String(localized: "darkmux no longer knows this app. Pair again.")
        case 403 where isEarlierPairing(client):
            return String(localized: "This work copy belongs to an earlier pairing with darkmux. Set up a new work copy with New work copy (a new branch; the earlier commits stay on the old one).")
        case 404: return String(localized: "darkmux doesn't have that anymore.")
        case 409 where client.message.localizedCaseInsensitiveContains("no free workspace name"):
            return String(localized: "darkmux has no free work copy name left for this project. Remove an old work copy of it in darkmux, then try again.")
        case 409 where client.message.localizedCaseInsensitiveContains("isn't on a branch") || client.message.localizedCaseInsensitiveContains("not on a branch"):
            return String(localized: "The work copy isn't on a branch, so darkmux can't hand over its changes.")
        case 409 where client.message.localizedCaseInsensitiveContains("default branch"):
            return String(localized: "darkmux couldn't find the repo's default branch on GitHub. Check the checkout's remote, then try again.")
        case 409: return String(localized: "darkmux is busy with that right now. Try again in a moment.")
        case 429: return String(localized: "darkmux is already running two of this app's runs. This one waits for a free slot.")
        case 400..<500: return String(localized: "darkmux didn't accept that. Show details has why.")
        default: return String(localized: "darkmux ran into a problem. Try again in a moment.")
        }
    }

    /// A refusal whose sentence says what happened (not just "couldn't start").
    static func saysWhy(_ error: any Error) -> Bool {
        guard let client = error as? DarkmuxClient.ClientError else { return false }
        return isEarlierPairing(error) || client.code == "branch_failed"
    }

    /// darkmux refused a workspace made for this app's earlier pairing.
    static func isEarlierPairing(_ error: any Error) -> Bool {
        guard let client = error as? DarkmuxClient.ClientError else { return false }
        return client.status == 403 && client.message.localizedCaseInsensitiveContains("not made for this app")
    }

    /// The raw text for Show details.
    static func details(_ error: any Error) -> String? {
        if let client = error as? DarkmuxClient.ClientError {
            return [client.status > 0 ? "darkmux answered \(client.status)" : nil, client.code, client.message].compactMap { $0 }.joined(separator: ": ")
        }
        return error.localizedDescription
    }
}
