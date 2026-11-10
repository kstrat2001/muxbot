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
    enum ID: String, Sendable, CaseIterable { case mac, darkmux, endpoint, lmStudio, docker, pair, models, github }
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
            steps.append(later(.darkmux, String(localized: "darkmux installed"), String(localized: "On your Mac.")))
            steps.append(later(.endpoint, String(localized: "darkmux's app connection"), String(localized: "On your Mac.")))
            steps.append(later(.lmStudio, String(localized: "LM Studio and a model"), String(localized: "On your Mac.")))
            steps.append(later(.docker, String(localized: "Docker"), String(localized: "On your Mac.")))
            steps.append(later(.pair, String(localized: "Pair Mux Bot"), String(localized: "On your Mac.")))
            steps.append(later(.models, String(localized: "Models Mux Bot can use"), String(localized: "On your Mac.")))
        } else {
            steps.append(SetupStep(
                id: .darkmux, title: String(localized: "darkmux installed"), state: up ? .done : .unknown,
                detail: up ? String(localized: "darkmux is answering on this Mac.")
                    : String(localized: "Mux Bot can't install darkmux or tell it's there until darkmux answers. darkmux's guide shows how to get it."),
                link: up ? nil : DarkmuxLinks.install, linkTitle: up ? nil : String(localized: "Get darkmux")))
            steps.append(SetupStep(
                id: .endpoint, title: String(localized: "darkmux's app connection"), state: up ? .done : .todo,
                detail: up ? String(localized: "Running on this Mac.")
                    : String(localized: "darkmux's app connection isn't running on this Mac. darkmux's guide shows how to start it; this ticks off once it answers."),
                link: up ? nil : DarkmuxLinks.guide, linkTitle: up ? nil : String(localized: "darkmux guide")))
            let tier = memoryTier(gb: f.memoryGB)
            let getLM = f.lmStudioApp == .notInstalled
            switch f.lmStudio {
            case let .models(n) where n > 0:
                steps.append(SetupStep(id: .lmStudio, title: String(localized: "LM Studio and a model"), state: .done,
                                       detail: String(localized: "LM Studio has \(n) models.")))
            case .models:
                steps.append(SetupStep(id: .lmStudio, title: String(localized: "LM Studio and a model"), state: .todo,
                                       detail: String(localized: "Download a model in LM Studio. This Mac has \(f.memoryGB) GB, so pick one darkmux's \(tier) settings fit."),
                                       action: .openLMStudio))
            case .notAnswering, .unknown:
                let ok = f.runningModels > 0
                let detail: String = ok ? String(localized: "darkmux has models ready.")
                    : [.installed, .running].contains(f.lmStudioApp)
                        ? String(localized: "LM Studio is installed, but its local server isn't answering. Open it, download a model and turn on its local server. This Mac has \(f.memoryGB) GB: darkmux's \(tier) settings fit it.")
                        : String(localized: "Install LM Studio and download a model, then turn on its local server. This Mac has \(f.memoryGB) GB: darkmux's \(tier) settings fit it.")
                steps.append(SetupStep(id: .lmStudio, title: String(localized: "LM Studio and a model"),
                                       state: ok ? .done : f.lmStudio == .unknown && f.lmStudioApp == .unknown ? .unknown : .todo,
                                       detail: detail,
                                       link: ok || !getLM ? nil : lmStudioURL, linkTitle: ok || !getLM ? nil : String(localized: "Get LM Studio"),
                                       action: ok || getLM || f.lmStudioApp == .unknown ? nil : .openLMStudio))
            }
            steps.append(dockerStep(f))
            if f.paired {
                steps.append(SetupStep(id: .pair, title: String(localized: "Pair Mux Bot"), state: .done,
                                       detail: String(localized: "Mux Bot is paired with darkmux on this Mac.")))
            } else if up {
                steps.append(SetupStep(id: .pair, title: String(localized: "Pair Mux Bot"), state: .todo,
                                       detail: String(localized: "Pair once, then approve it in darkmux on this Mac."), action: .pair))
            } else {
                steps.append(later(.pair, String(localized: "Pair Mux Bot"), String(localized: "After darkmux's app connection is running.")))
            }
            if !f.paired {
                steps.append(later(.models, String(localized: "Models Mux Bot can use"), String(localized: "After pairing.")))
            } else {
                switch f.listing {
                case .loading:
                    steps.append(SetupStep(id: .models, title: String(localized: "Models Mux Bot can use"), state: .unknown,
                                           detail: String(localized: "Looking at this Mac's models…")))
                case let .failed(reason):
                    steps.append(SetupStep(id: .models, title: String(localized: "Models Mux Bot can use"), state: .todo,
                                           detail: String(localized: "darkmux didn't list its models: \(reason)")))
                case .listed:
                    steps.append(SetupStep(id: .models, title: String(localized: "Models Mux Bot can use"),
                                           state: f.runningModels > 0 ? .done : .todo,
                                           detail: f.runningModels > 0
                                               ? String(localized: "\(f.listedModels) models, \(f.runningModels) ready now.")
                                               : String(localized: "darkmux lists \(f.listedModels) models but none answer now. Open LM Studio, or start your model's server.")))
                }
            }
        }
        steps.append(SetupStep(id: .github, title: String(localized: "GitHub (optional)"), state: f.githubSignedIn ? .done : .todo,
                               detail: f.githubSignedIn ? String(localized: "Signed in.")
                                   : String(localized: "Sign in to read private repos and open pull requests."),
                               action: f.githubSignedIn ? nil : .gitHubSignIn))
        return steps
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

    static func summary(_ steps: [SetupStep]) -> String {
        let done = steps.filter { $0.state == .done }.count
        return done == steps.count ? String(localized: "All set") : String(localized: "\(done) of \(steps.count) done")
    }

    /// The steps as text, to send to the Mac from a phone: no commands,
    /// the Mac's own Setup check walks through each one.
    static func shareText() -> String {
        """
        Set up Mux Bot on a Mac with Apple silicon:
        1. Get darkmux: \(DarkmuxLinks.install.absoluteString)
        2. Get LM Studio (\(lmStudioURL.absoluteString)) and download a model, and Docker Desktop (\(dockerURL.absoluteString)).
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
}
