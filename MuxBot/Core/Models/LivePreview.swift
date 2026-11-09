import Foundation

/// A bot's live preview as darkmux runs it (from the repo's
/// `.darkmux/preview.json`), and which URL the preview panel shows.
struct LivePreview: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case waiting, starting, installing, ready, stopped
        case failed(String)
        /// darkmux won't run one for this bot, and why (not a failure: the
        /// panel shows the reason and its fix).
        case unavailable(Unavailable)

        var isFailed: Bool { if case .failed = self { true } else { false } }
        var isUnavailable: Bool { if case .unavailable = self { true } else { false } }
        /// Asking again may start it: it failed, or the reason may be fixed by now.
        var canRetry: Bool {
            switch self {
            case .failed, .unavailable, .stopped, .waiting: true
            case .starting, .installing, .ready: false
            }
        }

        var text: String {
            switch self {
            case .waiting: "Waiting for darkmux…"
            case .starting: "Starting the preview…"
            case .installing: "Installing the project's dependencies (first time only)…"
            case .ready: "Preview ready."
            case .stopped: "The preview is stopped."
            // darkmux's own words go behind "Show details" (`PreviewFailure`).
            case .failed: String(localized: "The preview couldn't start.")
            case let .unavailable(why): why.title
            }
        }
    }

    var status: Status
    var url: URL?
    /// The dev server's last lines, when it failed.
    var log: String?

    /// darkmux's preview once it's ready; nothing while it starts or after
    /// it failed (the panel shows why); your own preview link otherwise.
    static func url(darkmux: LivePreview?, resource: URL?) -> URL? {
        switch darkmux?.status {
        case .ready?: darkmux?.url
        case .waiting?, .starting?, .installing?, .failed?: nil
        case .stopped?, .unavailable?, nil: resource
        }
    }

    /// Why darkmux won't run a bot's preview, told apart from its refusal.
    enum Unavailable: Equatable, Sendable {
        /// `clients.preview.enabled` is off on this Mac (darkmux's default).
        case previewsOff
        /// darkmux cloned the repo, so it has no checkout of yours to read
        /// the recipe from.
        case notYourCheckout
        /// A project made from a template: darkmux has no checkout of yours
        /// for it yet.
        case newProject
        /// Your checkout has no `.darkmux/preview.json`.
        case noRecipe

        /// The command that turns previews on (run by you: the app can't).
        static let enableCommand = "darkmux config set clients.preview.enabled true"

        var title: String {
            switch self {
            case .previewsOff: String(localized: "Previews are off on this Mac")
            case .notYourCheckout: String(localized: "No checkout of yours to preview")
            case .newProject: String(localized: "No preview for new projects yet")
            case .noRecipe: String(localized: "This project has no preview setup")
            }
        }

        /// What's going on, in plain words. `folder` is your checkout's name.
        func detail(repo: String?, folder: String?) -> String {
            let repo = repo ?? String(localized: "this repo")
            switch self {
            case .previewsOff:
                return String(localized: "A preview runs the project's own code, which a bot may have changed, in a container of its own on this Mac. So darkmux keeps previews off until you turn them on. Run this in Terminal, then try again:")
            case .notYourCheckout:
                return String(localized: "darkmux cloned \(repo), and it runs a preview only from your own checkout, never from a copy a bot writes to. Add your checkout of \(repo) and the preview starts from it.")
            case .newProject:
                return String(localized: "darkmux runs a preview only from a checkout of yours, and a project made from a template doesn't have one yet. This needs a darkmux update.")
            case .noRecipe:
                let folder = folder ?? String(localized: "your checkout")
                return String(localized: "darkmux starts a preview from .darkmux/preview.json in \(folder), and there isn't one. Add it there (darkmux never reads the copy a bot writes to), then try again.")
            }
        }

        /// darkmux's refusal of a preview start or status, as a reason; nil
        /// for any other error. darkmux answers in words, so this matches
        /// its status code and the start of its sentence.
        static func from(status: Int, message: String, template: Bool) -> Unavailable? {
            let m = message.lowercased()
            switch status {
            case 403 where m.hasPrefix("previews are off"):
                return .previewsOff
            case 404 where m.contains("not made from a checkout of yours"):
                return template ? .newProject : .notYourCheckout
            case 404 where m.contains("no .darkmux/preview.json"):
                return .noRecipe
            default:
                return nil
            }
        }
    }
}

/// A preview that didn't start, said in plain words: what happened and what
/// to do. darkmux's reason and the dev server's output are the details, shown
/// only when asked for (never paths, stack traces or exit codes up front).
struct PreviewFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The project needs a newer Node than the preview has.
        case nodeTooOld
        /// Installing the project's packages didn't work.
        case installFailed
        /// Something else was using the preview's port.
        case portInUse
        /// The project's preview settings aren't in a form darkmux reads.
        case settings
        /// It didn't come up in time.
        case tooSlow
        /// The project's own server stopped right after starting.
        case serverStopped
        case other
    }

    let kind: Kind
    let details: String

    init(reason: String, log: String?) {
        let log = log ?? ""
        let all = (reason + "\n" + log).lowercased()
        details = log.isEmpty ? reason : reason + "\n\n" + log
        // The cause before its symptoms: a Node too old for the project makes
        // npm skip packages, which then can't be found.
        kind = if all.contains("ebadengine") || all.contains("unsupported engine") || all.contains("requires node") {
            .nodeTooOld
        } else if all.contains("eaddrinuse") || all.contains("address already in use") {
            .portInUse
        } else if all.contains("preview.json") || all.contains("schema_version") {
            .settings
        } else if all.contains("cannot find module") || all.contains("native binding") || all.contains("npm err")
                    || all.contains("npm error") || all.contains("install failed") {
            .installFailed
        } else if all.contains("didn't start within") {
            .tooSlow
        } else if all.contains("dev server exited") {
            .serverStopped
        } else {
            .other
        }
    }

    var headline: String { String(localized: "The preview couldn't start.") }

    /// One plain sentence on what happened and what to do.
    var explanation: String {
        switch kind {
        case .nodeTooOld:
            String(localized: "This project needs a newer version of Node than the preview has. darkmux needs an update for it.")
        case .installFailed:
            String(localized: "Installing the project's packages didn't work. Try again; if it keeps happening, ask the bot to fix it.")
        case .portInUse:
            String(localized: "Another program was using the preview's port. Try again.")
        case .settings:
            String(localized: "The project's preview settings aren't in a form darkmux can use. Ask the bot to fix them.")
        case .tooSlow:
            String(localized: "The preview took too long to start. Try again.")
        case .serverStopped:
            String(localized: "The project's own server stopped right after it started. Ask the bot to look at it, or try again.")
        case .other:
            String(localized: "Something went wrong while starting it. Try again.")
        }
    }
}
