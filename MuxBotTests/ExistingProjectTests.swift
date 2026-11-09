import Foundation
import Testing
@testable import MuxBot

/// "Work on a project I already have": your own code, from a folder on this
/// Mac or a repo on your GitHub. Skills come from the project's own
/// PLAYBOOK.md, else the general ones; the bot keeps the repo, never a path.
struct ExistingProjectTests {
    @Test(arguments: [("kstrat2001/darklyenergized", "Darklyenergized"),
                      ("kstrat2001/muxbot-template-vite-react", "Muxbot Template Vite React"),
                      ("someone/my_site.v2", "My Site V2"),
                      ("hcr", "Hcr")])
    func aNameIsSuggestedFromTheRepo(repo: String, name: String) {
        #expect(ExistingProject.suggestedName(repo: repo) == name)
    }

    @Test @MainActor func aProjectsOwnPlaybookGivesTheSkills() {
        let (playbook, source) = ExistingProject.playbook(projectText: PlaybookParserTests.website)
        #expect(source == .projectPlaybook)
        #expect(playbook.skills.map(\.name) == ["Add a page", "Change the look"])
    }

    @Test @MainActor func noPlaybookOrABrokenOneGivesTheGeneralSkills() {
        for text in [nil, "not a playbook", "schema: 2\ntitle: x\nicon: y\npitch: z\n"] as [String?] {
            let (playbook, source) = ExistingProject.playbook(projectText: text)
            #expect(source == .general)
            #expect(playbook.skills.map(\.name).contains("Fix a bug"))
            #expect(playbook.persona.contains("{name}"))
        }
    }

    @Test @MainActor func theGreetingSaysWhyACloneHasNoPreview() {
        let clone = ExistingProject.greeting(name: "DE", source: .github(repo: "a/b", checkout: nil), skills: .general)
        #expect(clone.contains("no preview"))
        #expect(clone.contains("no PLAYBOOK.md"))
        let own = ExistingProject.greeting(name: "DE", source: .github(repo: "a/b", checkout: .init(bookmark: Data([1]), folderName: "b")), skills: .projectPlaybook)
        #expect(!own.contains("no preview"))
        #expect(own.contains("PLAYBOOK.md"))
    }
}

@Suite(.serialized) @MainActor
struct ExistingProjectFlowTests {
    @Test func aRepoFromGitHubIsClonedAndNoPathIsStored() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        var asked: DarkmuxClient.WorkspaceBody?
        brain.runs.workspaceMaker = { body in
            asked = body
            return DarkmuxClient.Workspace(workspace: "de-1", branch: "mux/de-1", created: true)
        }
        let (bot, problem) = await ExistingProject.start(.github(repo: "kstrat2001/darklyenergized", checkout: nil),
                                                         name: "Darkly Energized", purpose: "my consulting site",
                                                         projectPlaybook: nil, store: store, runs: brain.runs)
        #expect(problem == nil)
        #expect(bot.repoSlugs == ["kstrat2001/darklyenergized"])
        #expect(asked?.repoURL == "https://github.com/kstrat2001/darklyenergized")
        #expect(asked?.sourcePath == nil)
        #expect(asked?.template != true)
        #expect(bot.useCaseId.isEmpty, "not a template bot")
        #expect(bot.skills.map(\.name).contains("Fix a bug"))
        #expect(bot.instructions.contains("my consulting site"))
        // Nothing synced holds a path on this Mac.
        let synced = [bot.name, bot.instructions] + (bot.resources ?? []).map(\.value)
        #expect(!synced.contains { $0.contains("/Users/") || $0.hasPrefix("/") || $0.hasPrefix("~") })
        let thread = store.conversation(for: .bot(bot.id)).messages ?? []
        #expect(thread.contains { $0.content.contains("no preview") })
    }

    @Test func yourOwnCheckoutOfThePickedRepoIsUsedInstead() async {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let other = store.add(name: "Old DE bot", instructions: "")
        store.addResource(.repo, "https://github.com/kstrat2001/darklyenergized", to: other)
        other.folderBookmark = Data("bookmark".utf8)
        other.folderName = "darklyenergized"
        let checkout = ExistingProject.knownCheckout(for: "kstrat2001/DarklyEnergized", among: store.allBots())
        #expect(checkout == ExistingProject.Checkout(bookmark: Data("bookmark".utf8), folderName: "darklyenergized"))
        #expect(ExistingProject.knownCheckout(for: "kstrat2001/hcr", among: store.allBots()) == nil)

        brain.runs.workspaceMaker = { _ in DarkmuxClient.Workspace(workspace: "de-2", branch: "mux/de-2", created: true) }
        let (bot, _) = await ExistingProject.start(.github(repo: "kstrat2001/darklyenergized", checkout: checkout),
                                                   name: "DE", purpose: "site", projectPlaybook: PlaybookParserTests.website,
                                                   store: store, runs: brain.runs)
        #expect(bot.folderBookmark == Data("bookmark".utf8), "the bookmark stays on this Mac (LocalBotState)")
        #expect(bot.folderName == "darklyenergized")
        #expect(bot.skills.map(\.name) == ["Add a page", "Change the look"], "the project's own playbook")
        #expect(!(store.conversation(for: .bot(bot.id)).messages ?? []).contains { $0.content.contains("no preview") })
    }
}

/// Your GitHub repos for the picker: every page (Link rel="next"), only
/// back to api.github.com, with your token, up to a cap.
@Suite(.serialized) @MainActor
struct MyReposTests {
    private func signedIn() -> GitHubAuth {
        let keychain = MemoryKeychain(); keychain.items[GitHubAuth.tokenKey] = "ghu_abc"
        return GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: keychain, sleep: { _ in })
    }

    private func next(_ page: Int) -> [String: String] {
        ["Link": "<https://api.github.com/user/repos?per_page=100&page=\(page)>; rel=\"next\""]
    }

    @Test func everyPageIsRead() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /user/repos", 200, #"[{"full_name":"kstrat2001/darkmux","private":false,"description":"CLI"}]"#, headers: next(2))
        GitHubStub.on("GET /user/repos", 200, #"[{"full_name":"kstrat2001/darklyenergized","private":true,"description":null}]"#)
        let (repos, truncated) = try await signedIn().myRepos()
        #expect(repos.map(\.fullName) == ["kstrat2001/darkmux", "kstrat2001/darklyenergized"])
        #expect(repos.last?.isPrivate == true)
        #expect(!truncated)
        let first = try #require(GitHubStub.seen.first)
        #expect(first.query?.contains("affiliation=owner,collaborator,organization_member") == true)
        #expect(GitHubStub.seen.allSatisfy { $0.auth == "Bearer ghu_abc" })
    }

    @Test func itStopsAtThePageCapAndSaysSo() async throws {
        GitHubStub.reset()
        for page in 1...(GitHubAuth.repoPageCap + 2) {
            GitHubStub.on("GET /user/repos", 200, "[{\"full_name\":\"a/r\(page)\",\"private\":false}]", headers: next(page + 1))
        }
        let (repos, truncated) = try await signedIn().myRepos()
        #expect(repos.count == GitHubAuth.repoPageCap)
        #expect(truncated)
    }

    @Test func signedOutItAsksForSignInFirst() async {
        let auth = GitHubAuth(clientID: "Iv23test", session: GitHubStub.session, keychain: MemoryKeychain(), sleep: { _ in })
        await #expect(throws: GitHubError.self) { try await auth.myRepos() }
    }
}
