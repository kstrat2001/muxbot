import Foundation
import Testing
@testable import MuxBot

/// Kain's rule: Mux Bot never tells you to run a command. Each spot is a
/// button, an official page, or something darkmux does itself.
enum NoCommands {
    static let banned = ["Terminal", "brew ", "darkmux client", "darkmux doctor", "darkmux init", "darkmux config",
                         "darkmux claim", "client serve", "client approve", "client revoke", "claim command", ".darkmux/"]
    static func says(_ text: String) -> String? { banned.first { text.contains($0) } }
}

@MainActor
struct NoCommandsTests {
    private func macFacts(up: Bool?, paired: Bool = false) -> [SetupFacts] {
        var all: [SetupFacts] = []
        for lm in [SetupFacts.LMStudio.unknown, .notAnswering, .models(0), .models(2)] {
            for d in [SetupFacts.AppPresence.unknown, .notInstalled, .installed, .running] {
                var f = SetupFacts(platform: .mac, appleSilicon: true, memoryGB: 64, endpointUp: up, lmStudio: lm)
                f.docker = d; f.lmStudioApp = d; f.paired = paired
                all.append(f)
            }
        }
        return all
    }

    @Test func setupStepsNeverSayRunThis() {
        for f in macFacts(up: false) + macFacts(up: true) + macFacts(up: true, paired: true) + [SetupFacts(platform: .phone, appleSilicon: false, memoryGB: 8)] {
            for step in SetupCheck.steps(f) {
                #expect(NoCommands.says(step.title + " " + step.detail) == nil, "\(step.id): \(step.detail)")
            }
        }
    }

    /// Item 1: darkmux itself comes from its own guide page.
    @Test func darkmuxNotAnsweringLinksItsGuide() {
        let steps = SetupCheck.steps(SetupFacts(platform: .mac, appleSilicon: true, memoryGB: 64, endpointUp: false))
        #expect(steps[.darkmux]?.link == DarkmuxLinks.install)
        #expect(steps[.darkmux]?.linkTitle == "Get darkmux")
        #expect(steps[.endpoint]?.link == DarkmuxLinks.guide)
        #expect(steps[.endpoint]?.detail == "darkmux's app connection isn't running on this Mac. darkmux's guide shows how to start it; this ticks off once it answers.")
    }

    @Test func pairingIsApprovedOnTheMac() {
        let steps = SetupCheck.steps(SetupFacts(platform: .mac, appleSilicon: true, memoryGB: 64, endpointUp: true))
        #expect(steps[.pair]?.detail == "Pair once, then approve it in darkmux on this Mac.")
    }

    @Test func thePhonesStepsHaveNoCommands() {
        let text = SetupCheck.shareText()
        #expect(NoCommands.says(text) == nil, "\(text)")
        #expect(text.contains(DarkmuxLinks.guide.absoluteString))
    }

    @Test func darkmuxNotRunningIsPlain() {
        let text = FleetConnection.plainError(URLError(.cannotConnectToHost))
        #expect(text == "darkmux isn't running on this Mac. darkmux's guide shows how to start it; then try again.")
    }

    @Test func previewProblemsNeverSayRunThis() {
        for why in [LivePreview.Unavailable.previewsOff, .notAnswering, .earlierPairing, .noRecipe, .notYourCheckout, .checkoutMoved, .newProject] {
            let detail = why.detail(repo: "kstrat2001/site", folder: "site")
            #expect(NoCommands.says(detail) == nil, "\(why): \(detail)")
        }
        #expect(LivePreview.Unavailable.previewsOff.detail(repo: nil, folder: nil).contains("container"))
    }

    @Test func anEarlierPairingsWorkCopyPointsAtNewWorkCopy() {
        let refused = DarkmuxClient.ClientError(message: "workspace not made for this app", status: 403)
        let line = DarkmuxPlain.sentence(refused)
        #expect(NoCommands.says(line) == nil)
        #expect(line.contains("New work copy"))
    }

    @Test func helpArticlesNeverSayRunThis() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MuxBot/Features/Guide/Help")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(NoCommands.says(text) == nil, "\(file.lastPathComponent)")
            #expect(!text.components(separatedBy: "\n").contains { $0.hasPrefix("    ") }, "\(file.lastPathComponent) has a command block")
        }
    }

    /// Item 23: the preview setup card says how it runs in words; the
    /// commands darkmux runs are behind Show details.
    @Test func previewSetupSaysHowItRunsInWords() {
        #expect(PreviewSetup.howItRuns(command: "npm run dev", install: "npm ci") == "Starts with its dev script; installs with npm.")
        #expect(PreviewSetup.howItRuns(command: "pnpm start", install: "pnpm install --frozen-lockfile") == "Starts with its start script; installs with pnpm.")
        #expect(PreviewSetup.howItRuns(command: "node ace serve --hmr", install: "") == "Starts with its own command.")
        #expect(PreviewSetup.howItRuns(command: "", install: "") == "How it starts isn't known yet: fill it in under Show details.")
    }

    /// Item 18: a project whose start Mux Bot can't work out still gets
    /// the card, to fill in, instead of a file to add by hand.
    @Test func noRecipeFoundStillOffersTheCard() {
        let store = TestStore.fresh()
        let bot = store.add(name: "DE", instructions: "")
        bot.folderName = "site"
        let brain = BotBrain()
        brain.checkoutFolder = { _ in URL(fileURLWithPath: "/tmp/site") }
        brain.checkoutReader = { _ in (nil, []) }
        brain.offerPreviewSetup(for: bot, store: store)
        let messages = store.conversation(for: .bot(bot.id)).messages ?? []
        #expect(messages.contains { $0.kind == .actionCard })
        for m in messages { #expect(NoCommands.says(m.content) == nil, "\(m.content)") }
    }
}
