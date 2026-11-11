import Foundation

/// What the setup check can see from inside the app. The app is sandboxed
/// and can't run commands, so it looks only at what answers: darkmux's app
/// connection on 127.0.0.1:8767, LM Studio's server on 127.0.0.1:1234, the
/// pairing, darkmux's model listing, and the GitHub sign-in.
struct SetupFacts: Equatable, Sendable {
    enum Platform: Equatable, Sendable { case mac, phone }
    enum LMStudio: Equatable, Sendable {
        case unknown
        case notAnswering
        case models(Int)
    }

    var platform: Platform
    var appleSilicon: Bool
    var memoryGB: Int
    /// nil until looked at.
    var endpointUp: Bool? = nil
    var lmStudio: LMStudio = .unknown
    /// You said Docker is running: only where the app can't look.
    var dockerConfirmed = false
    /// An app as the Mac reports it (installed, open); `unknown` where the
    /// app can't look (on a phone).
    enum AppPresence: Equatable, Sendable { case unknown, notInstalled, installed, running }
    var docker: AppPresence = .unknown
    var lmStudioApp: AppPresence = .unknown
    var paired = false
    var listing: ModelListing = .loading
    var listedModels = 0
    var runningModels = 0
    var githubSignedIn = false
}

struct SetupStep: Identifiable, Equatable, Sendable {
    enum ID: String, Sendable, CaseIterable { case mac, darkmux, lmStudio, docker, pair, models, github }
    enum State: Equatable, Sendable {
        case done
        case todo
        /// Can't tell from here yet.
        case unknown
        /// The app can't check it: you say when it's done.
        case manual
        /// Waits on an earlier step.
        case later
        /// On iPhone or iPad: runs need a Mac.
        case needsMac
        /// An optional row not set up: never shown as a to-do.
        case optional
    }
    enum Action: Equatable, Sendable { case pair, gitHubSignIn, confirmDocker, openDocker, openLMStudio }

    var id: ID
    var title: String
    var state: State
    /// One line in plain words: what it is, or what to do. Never a command
    /// to run: a button (`action`) or an official page (`link`) does it.
    var detail: String
    var link: URL? = nil
    var linkTitle: String? = nil
    var action: Action? = nil
}

extension Array where Element == SetupStep {
    subscript(id: SetupStep.ID) -> SetupStep? { first { $0.id == id } }
    func state(_ id: SetupStep.ID) -> SetupStep.State? { self[id]?.state }
}

enum SetupCheck {
    static let lmStudioURL = URL(string: "https://lmstudio.ai")!
    /// Docker's own Mac install page (never a brew command).
    static let dockerURL = URL(string: "https://docs.docker.com/desktop/setup/install/mac-install/")!

    static func presence(installed: Bool, running: Bool) -> SetupFacts.AppPresence {
        running ? .running : installed ? .installed : .notInstalled
    }
    static let dockerBundleID = "com.docker.docker"
    static let lmStudioBundleID = "ai.elementlabs.lmstudio"

    /// darkmux's tuned memory tiers (its README): 96 GB or more, 33 to 64 GB,
    /// 32 GB or less.
    static func memoryTier(gb: Int) -> String {
        gb >= 96 ? String(localized: "96 GB or more") : gb > 32 ? String(localized: "33 to 64 GB") : String(localized: "32 GB or less")
    }

    static func steps(_ f: SetupFacts) -> [SetupStep] {
        let onMac = f.platform == .mac
        let later: (SetupStep.ID, String, String) -> SetupStep = { SetupStep(id: $0, title: $1, state: .later, detail: $2) }
        var steps: [SetupStep] = []

        if onMac {
            steps.append(SetupStep(id: .mac, title: String(localized: "A Mac with Apple silicon"),
                                   state: f.appleSilicon ? .done : .todo,
                                   detail: f.appleSilicon ? String(localized: "This Mac has Apple silicon.")
                                       : String(localized: "darkmux is built for Apple silicon Macs; this Mac has an Intel chip, which darkmux hasn't been tested on.")))
        } else {
            steps.append(SetupStep(id: .mac, title: String(localized: "A Mac with Apple silicon"), state: .needsMac,
                                   detail: String(localized: "Runs happen on a Mac. Set up darkmux and Mux Bot there; your bots and threads sync here."),
                                   link: DarkmuxLinks.guide))
        }

        let up = f.endpointUp == true
        if !onMac {
            steps.append(later(.darkmux, String(localized: "darkmux"), String(localized: "On your Mac.")))
            steps.append(later(.docker, String(localized: "Docker"), String(localized: "On your Mac.")))
            steps.append(later(.pair, String(localized: "Pair Mux Bot"), String(localized: "On your Mac.")))
            steps.append(later(.models, String(localized: "Models Mux Bot can use"), String(localized: "On your Mac.")))
            steps.append(later(.lmStudio, lmStudioTitle, String(localized: "On your Mac.")))
        } else {
            // One row: the app can't tell "not installed" from "not started".
            steps.append(SetupStep(
                id: .darkmux, title: String(localized: "darkmux"), state: up ? .done : .todo,
                detail: up ? String(localized: "darkmux is running on this Mac.")
                    : String(localized: "darkmux isn't answering on this Mac. Install it or start it; darkmux's guide shows both."),
                link: up ? nil : DarkmuxLinks.guide, linkTitle: up ? nil : String(localized: "darkmux guide")))
            steps.append(dockerStep(f))
            if f.paired {
                steps.append(SetupStep(id: .pair, title: String(localized: "Pair Mux Bot"), state: .done,
                                       detail: String(localized: "Mux Bot is paired with darkmux on this Mac.")))
            } else if up {
                steps.append(SetupStep(id: .pair, title: String(localized: "Pair Mux Bot"), state: .todo,
                                       detail: String(localized: "Pair once, then approve it in darkmux on this Mac."), action: .pair))
            } else {
                steps.append(later(.pair, String(localized: "Pair Mux Bot"), String(localized: "After darkmux is running.")))
            }
            steps.append(modelsStep(f))
            steps.append(lmStudioStep(f))
        }
        steps.append(SetupStep(id: .github, title: String(localized: "GitHub (optional)"), state: f.githubSignedIn ? .done : .optional,
                               detail: f.githubSignedIn ? String(localized: "Signed in.")
                                   : String(localized: "Sign in to read private repos and open pull requests."),
                               action: f.githubSignedIn ? nil : .gitHubSignIn))
        return steps
    }

    static var lmStudioTitle: String { String(localized: "LM Studio (optional)") }

    /// What the models step says when there's no model to use yet.
    static var needsEngineLine: String {
        String(localized: "darkmux needs a model engine set up on this Mac (Flint, TensorFold or LM Studio). darkmux's guide shows how.")
    }

    /// Required: a model darkmux lists that answers now. Any engine darkmux
    /// runs (Flint, TensorFold, LM Studio) counts.
    static func modelsStep(_ f: SetupFacts) -> SetupStep {
        let title = String(localized: "Models Mux Bot can use")
        let needsEngine = SetupStep(id: .models, title: title, state: .todo, detail: needsEngineLine,
                                    link: DarkmuxLinks.models, linkTitle: String(localized: "darkmux guide"))
        guard f.paired else {
            // LM Studio already has models: only pairing is left.
            if case let .models(n) = f.lmStudio, n > 0 {
                return SetupStep(id: .models, title: title, state: .later, detail: String(localized: "After pairing."))
            }
            // The app can't see darkmux's engines (Flint, TensorFold) until
            // pairing: wait, and say where to look if there isn't one.
            return SetupStep(id: .models, title: title, state: .later,
                             detail: String(localized: "After pairing, this checks darkmux's models. No model engine yet? darkmux's guide shows how (Flint, TensorFold or LM Studio)."),
                             link: DarkmuxLinks.models, linkTitle: String(localized: "darkmux guide"))
        }
        switch f.listing {
        case .loading:
            return SetupStep(id: .models, title: title, state: .unknown, detail: String(localized: "Looking at this Mac's models…"))
        case let .failed(reason):
            return SetupStep(id: .models, title: title, state: .todo, detail: String(localized: "darkmux didn't list its models: \(reason)"))
        case .listed:
            if f.runningModels > 0 {
                return SetupStep(id: .models, title: title, state: .done,
                                 detail: String(localized: "\(f.listedModels) models, \(f.runningModels) ready now."))
            }
            if f.listedModels == 0 { return needsEngine }
            return SetupStep(id: .models, title: title, state: .todo,
                             detail: String(localized: "darkmux lists \(f.listedModels) models, but none answer now. Start the engine they run on (Flint, TensorFold or LM Studio); darkmux's guide shows how."),
                             link: DarkmuxLinks.models, linkTitle: String(localized: "darkmux guide"))
        }
    }

    /// Optional: one engine darkmux can run models with, still detected.
    static func lmStudioStep(_ f: SetupFacts) -> SetupStep {
        let title = lmStudioTitle
        let tier = memoryTier(gb: f.memoryGB)
        switch f.lmStudio {
        case let .models(n) where n > 0:
            return SetupStep(id: .lmStudio, title: title, state: .done, detail: String(localized: "LM Studio has \(n) models."))
        case .models:
            return SetupStep(id: .lmStudio, title: title, state: .optional,
                             detail: String(localized: "Download a model in LM Studio. This Mac has \(f.memoryGB) GB, so pick one darkmux's \(tier) settings fit."),
                             action: .openLMStudio)
        case .notAnswering, .unknown:
            switch f.lmStudioApp {
            case .installed, .running:
                return SetupStep(id: .lmStudio, title: title, state: .optional,
                                 detail: String(localized: "LM Studio is installed, but its local server isn't answering. Open it, download a model and turn on its local server."),
                                 action: .openLMStudio)
            case .notInstalled:
                return SetupStep(id: .lmStudio, title: title, state: .optional,
                                 detail: String(localized: "One engine darkmux can run models with. You don't need it if you use Flint or TensorFold."),
                                 link: lmStudioURL, linkTitle: String(localized: "Get LM Studio"))
            case .unknown:
                return SetupStep(id: .lmStudio, title: title, state: .optional,
                                 detail: String(localized: "One engine darkmux can run models with."))
            }
        }
    }

    /// Docker as the Mac reports it: running is done; installed gets Open
    /// Docker; missing gets Docker's own install page. Asking you is only
    /// for where the app can't look.
    static func dockerStep(_ f: SetupFacts) -> SetupStep {
        let title = String(localized: "Docker")
        if f.docker == .running || (f.docker == .unknown && f.dockerConfirmed) {
            return SetupStep(id: .docker, title: title, state: .done,
                             detail: f.docker == .running ? String(localized: "Docker Desktop is running.") : String(localized: "You said Docker is running."))
        }
        switch f.docker {
        case .installed:
            return SetupStep(id: .docker, title: title, state: .todo,
                             detail: String(localized: "Docker Desktop is installed but not open. Open it and leave it running."), action: .openDocker)
        case .notInstalled:
            return SetupStep(id: .docker, title: title, state: .todo,
                             detail: String(localized: "darkmux runs each piece of work in Docker. Get Docker Desktop from Docker's site, then open it."),
                             link: dockerURL, linkTitle: String(localized: "Get Docker Desktop"))
        default:
            return SetupStep(id: .docker, title: title, state: .manual,
                             detail: String(localized: "darkmux runs each piece of work in Docker. Mux Bot can't check it from here; say when Docker Desktop is running."),
                             link: dockerURL, linkTitle: String(localized: "Get Docker Desktop"), action: .confirmDocker)
        }
    }

    /// Optional steps (LM Studio, GitHub) stay a row of their own, never in the count:
    /// a working setup without them is "All set".
    static let optional: Set<SetupStep.ID> = [.lmStudio, .github]

    static func summary(_ steps: [SetupStep]) -> String {
        let required = steps.filter { !optional.contains($0.id) }
        let done = required.filter { $0.state == .done }.count
        return done == required.count ? String(localized: "All set") : String(localized: "\(done) of \(required.count) done")
    }

    /// The steps as text, to send to the Mac from a phone: no commands,
    /// the Mac's own Setup check walks through each one.
    static func shareText() -> String {
        """
        Set up Mux Bot on a Mac with Apple silicon:
        1. Get darkmux: \(DarkmuxLinks.install.absoluteString)
        2. Get Docker Desktop (\(dockerURL.absoluteString)), and set up a model engine for darkmux: Flint, TensorFold or LM Studio. darkmux's guide shows how.
        3. Open Mux Bot on the Mac and ask it to check your setup: it walks you through the rest, and pairing.
        Guide: \(DarkmuxLinks.guide.absoluteString)
        """
    }
}

/// darkmux's official pages, the app's one place for them. Until darkmux
/// can start, approve and turn on previews by itself, the app points here
/// instead of at a command.
enum DarkmuxLinks {
    static let guide = URL(string: "https://darkmux.com/guide/")!
    /// Where to get darkmux (its guide, until it has an install page).
    static let install = URL(string: "https://darkmux.com/guide/")!
    /// Setting up a model engine (Flint, TensorFold, LM Studio): the guide's
    /// front page until darkmux's guide has a page for it.
    static let models = URL(string: "https://darkmux.com/guide/")!
}
