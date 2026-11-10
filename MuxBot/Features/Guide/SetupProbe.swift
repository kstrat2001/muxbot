import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Looks at what answers on this Mac, for the live setup checklist.
@MainActor
enum SetupProbe {
    static let dockerKey = "guide.setup.dockerConfirmed"

    /// `githubSignedIn` comes from `GitHubAuth` (its token is cached), so
    /// the checklist doesn't read the Keychain every few seconds.
    static func facts(connection: FleetConnection?, runs: RunCoordinator, githubSignedIn: Bool) async -> SetupFacts {
        #if os(macOS)
        var f = SetupFacts(platform: .mac, appleSilicon: isAppleSilicon, memoryGB: memoryGB)
        let base = connection?.client.baseURL ?? DarkmuxClient().baseURL
        async let endpoint = answers(base.appending(path: "/client/whoami"))
        async let lmStudio = lmStudioModels()
        f.endpointUp = await endpoint
        f.lmStudio = await lmStudio
        f.paired = connection?.isPaired ?? false
        f.docker = appPresence(bundleID: SetupCheck.dockerBundleID)
        f.lmStudioApp = appPresence(bundleID: SetupCheck.lmStudioBundleID)
        if f.paired, f.endpointUp == true {
            let listed = await runs.listedProfiles()
            f.listing = runs.listing
            f.listedModels = listed.count
            f.runningModels = listed.filter(\.reachable).count
        }
        #else
        var f = SetupFacts(platform: .phone, appleSilicon: false, memoryGB: memoryGB)
        #endif
        f.dockerConfirmed = UserDefaults.standard.bool(forKey: dockerKey)
        f.githubSignedIn = githubSignedIn
        return f
    }

    /// Looks once, then every `every` while `isLive` (the newest checklist).
    static func watch<Facts>(isLive: Bool, every: Duration, probe: () async -> Facts, show: (Facts) -> Void) async {
        repeat {
            show(await probe())
            guard isLive else { return }
            try? await Task.sleep(for: every)
        } while !Task.isCancelled
    }

    #if os(macOS)
    /// Installed (LaunchServices knows it) and open, for an app by bundle id.
    /// Both work in the sandbox; neither runs anything.
    static func appPresence(bundleID: String) -> SetupFacts.AppPresence {
        SetupCheck.presence(installed: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil,
                            running: NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID })
    }

    static func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    #endif

    static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// Any HTTP answer (a 401 included) means something is serving there.
    private static func answers(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: request))?.1 is HTTPURLResponse
    }

    private static func lmStudioModels() async -> SetupFacts.LMStudio {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1234/v1/models")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request), response is HTTPURLResponse else { return .notAnswering }
        struct Models: Decodable { var data: [Model]; struct Model: Decodable {} }
        return .models((try? JSONDecoder().decode(Models.self, from: data))?.data.count ?? 0)
    }
}
