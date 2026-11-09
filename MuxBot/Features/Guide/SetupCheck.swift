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
    /// You said Docker is running (the app can't see it; darkmux doctor can).
    var dockerConfirmed = false
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
    enum Action: Equatable, Sendable { case pair, gitHubSignIn, confirmDocker, openTerminal }

    var id: ID
    var title: String
    var state: State
    /// One line in plain words: what it is, or what to do.
    var detail: String
    var command: String? = nil
    var link: URL? = nil
    var action: Action? = nil
}

extension Array where Element == SetupStep {
    subscript(id: SetupStep.ID) -> SetupStep? { first { $0.id == id } }
    func state(_ id: SetupStep.ID) -> SetupStep.State? { self[id]?.state }
}

enum SetupCheck {
    static let installCommand = "brew tap kstrat2001/tap\nbrew install darkmux\ndarkmux init\ndarkmux doctor"
    static let lmStudioURL = URL(string: "https://lmstudio.ai")!
    static let dockerURL = URL(string: "https://www.docker.com/products/docker-desktop")!
    static let guideURL = URL(string: "https://darkmux.com/guide/")!

    /// darkmux's tuned memory tiers (its README): 96 GB or more, 33 to 64 GB,
    /// 32 GB or less.
    static func memoryTier(gb: Int) -> String {
        gb >= 96 ? String(localized: "96 GB or more") : gb > 32 ? String(localized: "33 to 64 GB") : String(localized: "32 GB or less")
    }

    static func steps(_ f: SetupFacts, serveCommand: String = "darkmux client serve") -> [SetupStep] {
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
                                   link: guideURL))
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
                    : String(localized: "Install it in Terminal with Homebrew (skip this if you have it). Mux Bot can't tell until darkmux's app connection runs."),
                command: up ? nil : installCommand, action: up ? nil : .openTerminal))
            steps.append(SetupStep(
                id: .endpoint, title: String(localized: "darkmux's app connection"), state: up ? .done : .todo,
                detail: up ? String(localized: "Running on this Mac.")
                    : String(localized: "Start it in Terminal and leave it running. It isn't in a darkmux release yet (5.9.3 doesn't have it); it comes in the next one."),
                command: up ? nil : serveCommand, action: up ? nil : .openTerminal))
            let tier = memoryTier(gb: f.memoryGB)
            switch f.lmStudio {
            case let .models(n) where n > 0:
                steps.append(SetupStep(id: .lmStudio, title: String(localized: "LM Studio and a model"), state: .done,
                                       detail: String(localized: "LM Studio has \(n) models.")))
            case .models:
                steps.append(SetupStep(id: .lmStudio, title: String(localized: "LM Studio and a model"), state: .todo,
                                       detail: String(localized: "Download a model in LM Studio. This Mac has \(f.memoryGB) GB, so pick one darkmux's \(tier) settings fit; darkmux doctor checks it."),
                                       link: lmStudioURL))
            case .notAnswering, .unknown:
                let ok = f.runningModels > 0
                steps.append(SetupStep(id: .lmStudio, title: String(localized: "LM Studio and a model"), state: ok ? .done : f.lmStudio == .unknown ? .unknown : .todo,
                                       detail: ok ? String(localized: "darkmux has models ready.")
                                           : String(localized: "Install LM Studio and download a model, or open it and turn on its local server. This Mac has \(f.memoryGB) GB: darkmux's \(tier) settings fit it."),
                                       link: ok ? nil : lmStudioURL))
            }
            steps.append(SetupStep(id: .docker, title: String(localized: "Docker"), state: f.dockerConfirmed ? .done : .manual,
                                   detail: f.dockerConfirmed ? String(localized: "You said Docker is running.")
                                       : String(localized: "darkmux runs each piece of work in Docker. Mux Bot can't check it from here; darkmux doctor does."),
                                   command: f.dockerConfirmed ? nil : "darkmux doctor", link: f.dockerConfirmed ? nil : dockerURL,
                                   action: f.dockerConfirmed ? nil : .confirmDocker))
            if f.paired {
                steps.append(SetupStep(id: .pair, title: String(localized: "Pair Mux Bot"), state: .done,
                                       detail: String(localized: "Mux Bot is paired with darkmux on this Mac.")))
            } else if up {
                steps.append(SetupStep(id: .pair, title: String(localized: "Pair Mux Bot"), state: .todo,
                                       detail: String(localized: "Pair once, then approve it in Terminal."), action: .pair))
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

    /// The installs Terminal can do, as one block to copy, with a rough
    /// time and download estimate. nil once they're done, or on a phone.
    struct SetupBlock: Equatable, Sendable {
        var command: String
        var estimate: String
    }

    static func setupBlock(_ steps: [SetupStep]) -> SetupBlock? {
        guard steps.state(.mac) != .needsMac else { return nil }
        let open: (SetupStep.ID) -> Bool = { id in steps.state(id).map { $0 != .done && $0 != .later } ?? false }
        let casks = [(SetupStep.ID.docker, "docker-desktop"), (.lmStudio, "lm-studio")].filter { open($0.0) }.map(\.1)
        var lines: [String] = []
        if !casks.isEmpty { lines.append("brew install --cask " + casks.joined(separator: " ")) }
        if open(.darkmux) { lines.append(installCommand) }
        guard !lines.isEmpty else { return nil }
        // A rough guide, not a measurement: the model is the big download.
        let estimate = open(.lmStudio)
            ? String(localized: "Roughly 20 to 40 minutes and 10 to 25 GB of downloads on a fresh Mac; the model you pick in LM Studio is most of it.")
            : String(localized: "Roughly 5 to 10 minutes and 2 to 3 GB of downloads.")
        return SetupBlock(command: lines.joined(separator: "\n"), estimate: estimate)
    }

    static func summary(_ steps: [SetupStep]) -> String {
        let done = steps.filter { $0.state == .done }.count
        return done == steps.count ? String(localized: "All set") : String(localized: "\(done) of \(steps.count) done")
    }

    /// The steps as text, to send to the Mac from a phone.
    static func shareText() -> String {
        """
        Set up Mux Bot on a Mac with Apple silicon:
        1. Install darkmux: brew tap kstrat2001/tap && brew install darkmux && darkmux init && darkmux doctor
        2. Install LM Studio (lmstudio.ai) and download a model, and Docker Desktop.
        3. Start darkmux's app connection: darkmux client serve (in the next darkmux release).
        4. Open Mux Bot on the Mac and pair it with darkmux.
        Guide: \(guideURL.absoluteString)
        """
    }
}
