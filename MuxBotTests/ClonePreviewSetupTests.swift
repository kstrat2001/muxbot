import Foundation
import Testing
@testable import MuxBot

/// darkmux's clone of a repo picked from GitHub (no checkout of yours):
/// "Set up preview" works the recipe out from the repo on GitHub, and
/// Approve hands it to darkmux (darkmux #3571) instead of writing a file.
@Suite(.serialized) @MainActor
struct ClonePreviewSetupTests {
    private func clone(_ store: BotStore) -> Bot {
        let bot = store.add(name: "Get Tested", instructions: "")
        store.addResource(.repo, "https://github.com/someone/get-tested", to: bot)
        bot.workspaceName = "get-tested"
        return bot
    }

    private func cards(_ store: BotStore, _ bot: Bot) -> [ChatMessage] {
        (store.conversation(for: .bot(bot.id)).messages ?? []).filter { $0.kind == .actionCard }
    }

    @Test func aClonesCardComesFromTheRepoAndApproveHandsItToDarkmux() async throws {
        let store = TestStore.fresh()
        let bot = clone(store)
        let brain = BotBrain()
        brain.checkoutFolder = { _ in nil }
        var asked: [String] = []
        brain.repoReader = { repo in
            asked.append(repo)
            return (#"{"scripts":{"dev":"vite"}}"#, ["package.json", "package-lock.json"])
        }
        var sent: (Data, String)?
        brain.runs.recipeSetter = { data, workspace in sent = (data, workspace) }

        #expect(brain.offerPreviewSetup(for: bot, store: store, again: true) == .preparing)
        for _ in 0..<100 where cards(store, bot).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let card = try #require(cards(store, bot).first)
        #expect(asked == ["someone/get-tested"])
        guard case let .setUpPreview(setup)? = card.action else { Issue.record("not a setup card"); return }
        #expect(setup.isClone)
        #expect(setup.envFromSource.isEmpty, "a clone has no checkout to copy from")
        #expect(!setup.command.value.isEmpty)

        brain.resolve(card, approve: true, store: store)
        for _ in 0..<100 where sent == nil { try await Task.sleep(for: .milliseconds(10)) }
        let (data, workspace) = try #require(sent)
        #expect(workspace == "get-tested")
        let recipe = try JSONDecoder().decode(DarkmuxClient.ApprovedRecipe.self, from: data)
        #expect(recipe.schemaVersion == "1.0")
        #expect(recipe.command == setup.command.value)
        #expect(LocalBotState.shared[bot.id]?.prFiles?[PreviewSetup.path] == nil, "nothing written for a pull request")
    }

    @Test func aBotWithNoWorkCopyStillNeedsItsCheckout() {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        let brain = BotBrain()
        brain.checkoutFolder = { _ in nil }
        #expect(brain.offerPreviewSetup(for: bot, store: store, again: true) == .needsCheckout)
    }

    @Test func theApprovedRecipeKeepsDarkmuxsShape() throws {
        var draft = ProjectSetupDetector.Draft()
        draft.command = .init(value: "npm run dev", source: "found package.json")
        var setup = PreviewSetup(draft, folderName: "site", clone: true)
        setup.env.value = "PORT={port}"
        setup.install.value = "npm ci"
        setup.ready.value = "/"
        let data = try #require(setup.recipeData)
        let recipe = try JSONDecoder().decode(DarkmuxClient.ApprovedRecipe.self, from: data)
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        let original = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(NSDictionary(dictionary: back ?? [:]).isEqual(to: original ?? [:]))
    }
}
