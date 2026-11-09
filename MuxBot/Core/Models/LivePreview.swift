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
            case let .failed(why): "The preview didn't start: \(why)\(why.hasSuffix(".") ? "" : ".")"
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
                return String(localized: "A preview runs the project's own code (its package.json scripts, which a bot may have changed) on this Mac as you, outside darkmux's sandbox. So darkmux keeps previews off until you turn them on. Run this in Terminal, then try again:")
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
