import Foundation

/// A bot's live preview as darkmux runs it (from the repo's
/// `.darkmux/preview.json`), and which URL the preview panel shows.
struct LivePreview: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case waiting, starting, installing, ready, stopped
        /// darkmux is making the bot's work copy (Add folder): the panel stays.
        case settingUpWorkCopy
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
            case .starting, .installing, .ready, .settingUpWorkCopy: false
            }
        }

        var text: String {
            switch self {
            case .waiting: "Waiting for darkmux…"
            case .settingUpWorkCopy: String(localized: "Setting up a work copy on this Mac…")
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
        case .waiting?, .starting?, .installing?, .failed?, .settingUpWorkCopy?: nil
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
        /// This app isn't paired with darkmux (or darkmux forgot it).
        case notPaired
        /// darkmux isn't answering on this Mac (not running).
        case notAnswering
        /// The template this project came from has no preview recipe.
        case templateNoRecipe
        /// A template project made by an older darkmux, which can't preview it.
        case remakeProject
        /// Your checkout moved or was deleted: darkmux's workspace is no
        /// longer a worktree of it.
        case checkoutMoved
        /// The work copy was made for this app's earlier pairing.
        case earlierPairing
        /// darkmux couldn't make the bot's work copy on this Mac.
        case noWorkCopy

        var title: String {
            switch self {
            case .previewsOff: String(localized: "Previews are off on this Mac")
            case .notYourCheckout: String(localized: "No checkout of yours to preview")
            case .newProject: String(localized: "No preview for new projects yet")
            case .notPaired: String(localized: "Mux Bot isn't paired with darkmux")
            case .notAnswering: String(localized: "darkmux isn't answering on this Mac")
            case .templateNoRecipe: String(localized: "This project's template has no preview")
            case .remakeProject: String(localized: "This project can't be previewed")
            case .checkoutMoved: String(localized: "Your checkout moved")
            case .earlierPairing: String(localized: "This work copy is from an earlier pairing")
            case .noRecipe: String(localized: "This project has no preview setup")
            case .noWorkCopy: String(localized: "darkmux couldn't get the project onto this Mac")
            }
        }

        /// What's going on, in plain words. `folder` is your checkout's name.
        func detail(repo: String?, folder: String?) -> String {
            let repo = repo ?? String(localized: "this repo")
            switch self {
            case .previewsOff:
                return String(localized: "A preview runs the project's own code, which a bot may have changed, in a container of its own on this Mac. So darkmux keeps previews off until you turn them on in darkmux on this Mac; darkmux's guide shows how. Then try again.")
            case .notYourCheckout:
                return String(localized: "darkmux cloned \(repo), and it runs a preview only from your own checkout, never from a copy a bot writes to. Add your checkout of \(repo) and the preview starts from it.")
            case .newProject:
                return String(localized: "darkmux runs a preview only from a checkout of yours, and a project made from a template doesn't have one yet. This needs a darkmux update.")
            case .notPaired:
                return String(localized: "Pair Mux Bot with darkmux on this Mac to see the preview.")
            case .notAnswering:
                return String(localized: "darkmux's app connection isn't running on this Mac. darkmux's guide shows how to start it; then try again.")
            case .templateNoRecipe:
                return String(localized: "The template this project was made from has no preview settings, so darkmux can't run a preview for it.")
            case .remakeProject:
                return String(localized: "It was made by an older darkmux, which didn't keep what a preview needs. Start the project again from its template to get a preview.")
            case .checkoutMoved:
                return String(localized: "darkmux's copy of \(repo) is no longer linked to your checkout (it moved, or was deleted). Add your checkout again.")
            case .earlierPairing:
                return String(localized: "darkmux made it for this app before you paired again, so it won't let this pairing use it. Set up a new work copy for it (a new branch; the earlier commits stay on the old one).")
            case .noWorkCopy:
                return String(localized: "darkmux makes its own copy of \(repo) on this Mac to show the preview and to work in, and that didn't work. Try again; Show details has what darkmux said.")
            case .noRecipe:
                let folder = folder ?? repo
                return String(localized: "darkmux needs to know how \(folder) starts before it can show a preview. Set up the preview: Mux Bot works it out from the project's files, and you check it.")
            }
        }

        /// darkmux's refusal of a preview start or status, as a reason; nil
        /// for any other error. darkmux answers in words, so this matches
        /// its status code and the start of its sentence.
        /// darkmux's `code` decides (client_pairing/client_workspace); its
        /// wording is only the fallback for an older darkmux without codes.
        static func from(status: Int, message: String, template: Bool, code: String?) -> Unavailable? {
            switch code {
            case "preview_disabled": return .previewsOff
            case "template_no_recipe": return .templateNoRecipe
            case "no_recipe": return .noRecipe
            case "no_source_checkout":
                if message.lowercased().contains("no longer a worktree") { return .checkoutMoved }
                return template ? .remakeProject : .notYourCheckout
            default: return from(status: status, message: message, template: template)
            }
        }

        static func from(status: Int, message: String, template: Bool) -> Unavailable? {
            let m = message.lowercased()
            switch status {
            case 403 where m.hasPrefix("previews are off"):
                return .previewsOff
            case 403 where m.contains("not made for this app"):
                return .earlierPairing
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
        /// Docker (darkmux runs previews in a container) isn't running.
        case docker
        /// The preview's container didn't start.
        case containerFailed
        /// The dev server listens only on 127.0.0.1 inside its container.
        case loopbackOnly
        /// The dev server never answered on its port.
        case notAnswering
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
        // darkmux's own reasons first (client_preview.rs), then the server's output.
        kind = if all.contains("requires docker") || all.contains("docker isn't running") || all.contains("docker is not running")
                    || all.contains("cannot connect to the docker daemon") {
            .docker
        } else if all.contains("container did not start") {
            .containerFailed
        } else if all.contains("container stopped itself") {
            .serverStopped
        } else if all.contains("listens on 127.0.0.1") || all.contains("bind 0.0.0.0") {
            .loopbackOnly
        } else if all.contains("didn't answer on port") {
            .notAnswering
        } else if all.contains("ebadengine") || all.contains("unsupported engine") || all.contains("requires node") {
            .nodeTooOld
        } else if all.contains("eaddrinuse") || all.contains("address already in use") {
            .portInUse
        } else if all.contains("preview.json") || all.contains("schema_version") {
            .settings
        } else if all.contains("cannot find module") || all.contains("native binding") || all.contains("npm err")
                    || all.contains("npm error") || all.contains("install failed")
                    || (all.contains("install (") && all.contains("exited")) {
            .installFailed
        } else if all.contains("didn't start within") {
            .tooSlow
        } else if all.contains("dev server exited") {
            .serverStopped
        } else {
            .other
        }
    }

    /// An install problem (a missing module or native binding, the wrong
    /// Node for the packages): Start over, which reinstalls them, is the
    /// main action.
    var startOverFirst: Bool { kind == .installFailed || kind == .nodeTooOld }

    /// What Start over does, in plain words.
    static let startOverNote = String(localized: "Reinstalls the project's packages, then starts the preview again. Your files aren't touched.")

    var headline: String { String(localized: "The preview couldn't start.") }

    /// One plain sentence on what happened and what to do.
    var explanation: String { explanation(template: false) }

    /// For a template project the recipe is the template's (its first
    /// commit); otherwise it's the one in your own checkout. Never the
    /// bot's copy: darkmux doesn't read that.
    func explanation(template: Bool) -> String {
        switch kind {
        case .nodeTooOld:
            String(localized: "This project needs a newer version of Node than the preview has. darkmux needs an update for it.")
        case .installFailed:
            String(localized: "Installing the project's packages didn't work. Try again; if it keeps happening, ask the bot to fix it.")
        case .portInUse:
            String(localized: "Another program was using the preview's port. Try again.")
        case .settings:
            template
                ? String(localized: "The template's preview settings aren't in a form darkmux can use, so this project's preview can't start until the template is fixed.")
                : String(localized: "The preview settings file in your checkout isn't in a form darkmux can use. Fix it in your checkout (darkmux never reads the bot's copy), then try again.")
        case .tooSlow:
            String(localized: "The preview took too long to start. Try again.")
        case .serverStopped:
            String(localized: "The project's own server stopped right after it started. Ask the bot to look at it, or try again.")
        case .docker:
            String(localized: "darkmux runs previews in a container, and Docker isn't running on this Mac. Open Docker, then try again.")
        case .containerFailed:
            String(localized: "The preview's container didn't start. Try again; if it keeps happening, restart Docker.")
        case .loopbackOnly:
            String(localized: "The project's server only listens inside its container. It needs to listen on 0.0.0.0 (set HOST in the preview settings).")
        case .notAnswering:
            String(localized: "The project's server started but never answered. Try again, or ask the bot to look at its dev script.")
        case .other:
            String(localized: "Something went wrong while starting it. Try again.")
        }
    }
}
