import Foundation
import Testing
@testable import MuxBot

/// Sweep batch 6b: starting a project fails plainly and recovers.
@Suite(.serialized) @MainActor
struct StartSweepTests {
    static let template = OwnRepoTests.template

    // 5: a template bot with a repo but no project here is still a template.

    private func templateBotWithRepo(_ store: BotStore) -> Bot {
        let bot = store.add(name: "Tides", instructions: "")
        bot.useCaseId = "book"
        store.addResource(.repo, "https://github.com/kain/tides", to: bot)
        return bot
    }

    @Test func aBackedUpTemplateBotWithNoProjectHereIsMadeFromItsTemplate() {
        let store = TestStore.fresh()
        let bot = templateBotWithRepo(store)
        #expect(RunBlocker.check(paired: true, crew: .coder, bot: bot) == .projectNotMade("Tides", here: true))
        #expect(RunBlocker.check(paired: true, crew: .coder, bot: bot, deviceRuns: false) == .projectNotMade("Tides", here: false))
    }

    @Test func itsWorkCopyComesFromTheTemplateAndItsGitHubStartIsFound() async {
        let store = TestStore.fresh()
        let bot = templateBotWithRepo(store)
        let runs = RunCoordinator()
        runs.templateSource = { _ in Self.template }
        let bodies = BodyLog()
        runs.workspaceMaker = { body in
            bodies.add(body)
            return DarkmuxClient.Workspace(workspace: "tides-1", branch: "main", head: "h", repo: nil, created: true, fetchError: nil)
        }
        runs.startFinder = { repo, entry in
            #expect(repo == "kain/tides")
            return (GitHubPR.Start(commit: "start1", branch: "main", head: "mux/tides"), entry.ref)
        }
        await runs.setUpWorkCopy(for: bot, store: store)
        let body = bodies.values.first
        #expect(body?.template == true, "a fresh project from the template, never a clone")
        #expect(body?.ref == Self.template.ref)
        #expect(bot.workspaceName == "tides-1")
        #expect(bot.repoSlugs == ["kain/tides"])
        #expect(bot.githubStart == GitHubPR.Start(commit: "start1", branch: "main", head: "mux/tides"), "backups go on")
    }

    @Test func theGitHubStartIsTheStartFromCommit() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kain/tides", 200, #"{"default_branch":"main"}"#)
        GitHubStub.on("GET /repos/kain/tides/commits", 200,
                      #"[{"sha":"w2","parents":[{"sha":"start1"}],"commit":{"message":"Back up Tides's work"}},{"sha":"start1","parents":[{"sha":"init0"}],"commit":{"message":"Start from kstrat2001/muxbot-template-book@e044900"}},{"sha":"init0","parents":[],"commit":{"message":"Initial commit"}}]"#)
        let found = try await GitHubRepoMaker(session: GitHubStub.session, token: "t").findStart(repo: "kain/tides", template: Self.template, botName: "Tides")
        #expect(found?.start == GitHubPR.Start(commit: "start1", branch: "main", head: "mux/tides"))
        #expect(found?.ref == Self.template.ref, "the pinned commit the repo started from")
    }

    private static let olderPinStart = #"[{"sha":"start1","parents":[{"sha":"init0"}],"commit":{"message":"Start from kstrat2001/muxbot-template-book@aaaaaaa"}},{"sha":"init0","parents":[],"commit":{"message":"Initial commit"}}]"#

    @Test func aRepoFromAnOlderPinStartsFromThatPin() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kain/tides", 200, #"{"default_branch":"main"}"#)
        GitHubStub.on("GET /repos/kain/tides/commits", 200, Self.olderPinStart)
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book/commits/aaaaaaa", 200, #"{"sha":"aaaaaaa1111111111111111111111111111111111"}"#)
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book", 200, #"{"default_branch":"main"}"#)
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book/compare/aaaaaaa1111111111111111111111111111111111...main", 200, #"{"status":"ahead"}"#)
        let found = try await GitHubRepoMaker(session: GitHubStub.session, token: "t").findStart(repo: "kain/tides", template: Self.template, botName: "Tides")
        #expect(found?.ref == "aaaaaaa1111111111111111111111111111111111")
    }

    @Test func aCommitTheTemplateNeverHadIsNoStart() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kain/tides", 200, #"{"default_branch":"main"}"#)
        GitHubStub.on("GET /repos/kain/tides/commits", 200, Self.olderPinStart)
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book/commits/aaaaaaa", 200, #"{"sha":"aaaaaaa1111111111111111111111111111111111"}"#)
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book", 200, #"{"default_branch":"main"}"#)
        // On a branch of the template that its default branch doesn't have.
        GitHubStub.on("GET /repos/kstrat2001/muxbot-template-book/compare/aaaaaaa1111111111111111111111111111111111...main", 200, #"{"status":"diverged"}"#)
        let found = try await GitHubRepoMaker(session: GitHubStub.session, token: "t").findStart(repo: "kain/tides", template: Self.template, botName: "Tides")
        #expect(found == nil, "never a ref the registry or the template's history doesn't vouch for")
    }

    @Test func aLaterStartFromCommitIsIgnored() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kain/tides", 200, #"{"default_branch":"main"}"#)
        GitHubStub.on("GET /repos/kain/tides/commits", 200,
                      #"[{"sha":"fake9","parents":[{"sha":"start1"}],"commit":{"message":"Start from kstrat2001/muxbot-template-book@bbbbbbb"}},{"sha":"start1","parents":[{"sha":"init0"}],"commit":{"message":"Start from kstrat2001/muxbot-template-book@e044900"}},{"sha":"init0","parents":[],"commit":{"message":"Initial commit"}}]"#)
        let found = try await GitHubRepoMaker(session: GitHubStub.session, token: "t").findStart(repo: "kain/tides", template: Self.template, botName: "Tides")
        #expect(found?.start.commit == "start1", "the repo's second commit, never a later one that says the same")
        #expect(found?.ref == Self.template.ref)
        #expect(!GitHubStub.seen.contains { $0.path.contains("bbbbbbb") }, "the later commit's ref is never looked up")
    }

    @Test func aSecondCommitThatIsntAStartIsNoStart() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kain/tides", 200, #"{"default_branch":"main"}"#)
        GitHubStub.on("GET /repos/kain/tides/commits", 200,
                      #"[{"sha":"fake9","parents":[{"sha":"c1"}],"commit":{"message":"Start from kstrat2001/muxbot-template-book@e044900"}},{"sha":"c1","parents":[{"sha":"init0"}],"commit":{"message":"Add a README"}},{"sha":"init0","parents":[],"commit":{"message":"Initial commit"}}]"#)
        let found = try await GitHubRepoMaker(session: GitHubStub.session, token: "t").findStart(repo: "kain/tides", template: Self.template, botName: "Tides")
        #expect(found == nil)
    }

    @Test func aLongHistoryStillFindsTheStart() async throws {
        GitHubStub.reset()
        GitHubStub.on("GET /repos/kain/tides", 200, #"{"default_branch":"main"}"#)
        // 201 commits: the newest 100, then (the list's last page) the first one alone.
        let work = (0..<100).map { #"{"sha":"w\#($0)","parents":[{"sha":"p\#($0)"}],"commit":{"message":"Back up Tides's work"}}"# }.joined(separator: ",")
        let api = "https://api.github.com/repos/kain/tides/commits?sha=main&per_page=100"
        GitHubStub.on("GET /repos/kain/tides/commits", 200, "[\(work)]",
                      headers: ["Link": "<\(api)&page=2>; rel=\"next\", <\(api)&page=3>; rel=\"last\""])
        GitHubStub.on("GET /repos/kain/tides/commits", 200, #"[{"sha":"init0","parents":[],"commit":{"message":"Initial commit"}}]"#,
                      headers: ["Link": "<\(api)&page=2>; rel=\"prev\", <\(api)&page=1>; rel=\"first\""])
        let older = (0..<99).map { #"{"sha":"o\#($0)","parents":[{"sha":"q\#($0)"}],"commit":{"message":"Back up Tides's work"}}"# }.joined(separator: ",")
        GitHubStub.on("GET /repos/kain/tides/commits", 200,
                      "[\(older)," + #"{"sha":"start1","parents":[{"sha":"init0"}],"commit":{"message":"Start from kstrat2001/muxbot-template-book@e044900"}}]"#)
        let found = try await GitHubRepoMaker(session: GitHubStub.session, token: "t").findStart(repo: "kain/tides", template: Self.template, botName: "Tides")
        #expect(found?.start.commit == "start1")
        let pages = GitHubStub.seen.filter { $0.path == "/repos/kain/tides/commits" }.compactMap(\.query)
        #expect(pages.count == 3 && pages[1].contains("page=3") && pages[2].contains("page=2"), "\(pages)")
    }

    @Test func aPageLinkToAnotherHostIsNeverFollowed() {
        #expect(GitHubAuth.linkedPage(#"<https://evil.example/x?page=9>; rel="last""#, rel: "last") == nil)
        #expect(GitHubAuth.linkedPage(#"<https://api.github.com/x?page=9>; rel="last""#, rel: "last") == "https://api.github.com/x?page=9")
    }

    // 10: an invalid PLAYBOOK.md says why.

    @Test func anInvalidProjectPlaybookSaysWhy() {
        let (playbook, source) = ExistingProject.playbook(projectText: "schema: 9\ntitle: x\n")
        #expect(playbook == ExistingProject.general)
        guard case let .invalid(why) = source else { Issue.record("\(source)"); return }
        #expect(why.contains("newer Mux Bot"), "\(why)")
        #expect(!why.contains("template"), "it's the project's file, not a template's: \(why)")
        let hello = ExistingProject.greeting(name: "Site", source: .folder(URL(fileURLWithPath: "/x")), skills: source)
        #expect(hello.contains(why))
        #expect(!hello.contains("has no PLAYBOOK.md"))
    }

    // 11: Start waits for the repo's PLAYBOOK.md.

    @Test func startWaitsForThePlaybook() {
        #expect(!ExistingProject.canStart(name: "Site", purpose: "a site", starting: false, readingPlaybook: true))
        #expect(ExistingProject.canStart(name: "Site", purpose: "a site", starting: false, readingPlaybook: false))
        #expect(!ExistingProject.canStart(name: " ", purpose: "a site", starting: false, readingPlaybook: false))
    }

    // 12: "darkmux cloned this repo" only when it did.

    @Test func theCloneLineOnlyWhenThereIsAClone() {
        let source = ExistingProject.Source.github(repo: "kain/site", checkout: nil)
        let notYet = ExistingProject.greeting(name: "Site", source: source, skills: .general, madeHere: false)
        #expect(!notYet.contains("darkmux cloned"))
        #expect(notYet.contains("once Mux Bot is paired"))
        #expect(ExistingProject.greeting(name: "Site", source: source, skills: .general, madeHere: true).contains("darkmux cloned"))
    }

    @Test func unpairedTheGreetingDoesntClaimAClone() async {
        let store = TestStore.fresh()
        let runs = RunCoordinator()
        let (bot, _) = await ExistingProject.start(.github(repo: "kain/site", checkout: nil), name: "Site", purpose: "x",
                                                   projectPlaybook: nil, store: store, runs: runs)
        let said = (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content)
        #expect(!said.contains { $0.contains("darkmux cloned") }, "\(said)")
    }

    // 14: signed out, backups say so once.

    @Test func signedOutABackupSaysSoOnce() async {
        let store = TestStore.fresh()
        let bot = templateBotWithRepo(store)
        bot.workspaceName = "tides-1"
        bot.githubStart = GitHubPR.Start(commit: "s1", branch: "main", head: "mux/tides")
        let runs = RunCoordinator()
        runs.githubToken = { nil }
        runs.changesFetcher = { _ in DarkmuxClient.Changes(base: "b", baseBranch: "main", head: "h", branch: "main", files: []) }
        await runs.backUp(bot, store: store)
        await runs.backUp(bot, store: store)
        let notes = (store.conversation(for: .bot(bot.id)).messages ?? []).map(\.content).filter { $0.contains("Not backed up") }
        #expect(notes == ["Not backed up: sign in with GitHub (Settings › GitHub) to back up to mux/tides."])
    }

    // 15: no lockfile, still an install.

    @Test func noLockfileStillInstalls() {
        let draft = ProjectSetupDetector.detect(packageJSON: #"{"scripts":{"dev":"vite"}}"#, files: ["package.json"])
        #expect(draft.install == .init(value: "npm install --no-audit --no-fund", source: "package.json, no lockfile"))
        #expect(ProjectSetupDetector.detect(packageJSON: nil, files: []).install == nil, "no package.json, no guess")
    }

    // 18: the guide's first bot from a link is a real project bot.

    @Test func theGuidesFirstBotFromALinkIsSetUpLikeWorkOnAProject() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        brain.github = MockGitHub()
        brain.runs.workspaceMaker = { _ in DarkmuxClient.Workspace(workspace: "site-1", branch: "mux/site-ab", head: "h", repo: nil, created: true, fetchError: nil) }
        let opened = BodyLog()
        brain.openBot = { opened.ids.append($0) }
        let draft = try #require(LeadGuide.draft(for: "https://github.com/kain/site"))
        let card = store.proposeAction(.createBot(draft), in: .lead)
        brain.resolve(card, approve: true, store: store)
        await brain.creatingBot?.value
        let bot = try #require(store.allBots().first { $0.name == "site" })
        #expect(bot.repoSlugs == ["kain/site"])
        #expect(bot.workspaceName == "site-1", "darkmux set up its work copy")
        #expect(!bot.skills.isEmpty, "it has skills, like Work on a project I already have")
        #expect(opened.ids == [bot.id], "and you're taken to it")
        #expect((store.conversation(for: .bot(bot.id)).messages ?? []).contains { $0.role == .assistant })
    }

    // 19: template fetch failures say what happened.

    @Test func aTemplateMissingAtItsPinSaysSo() async {
        let registry = TemplateRegistry(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), fetch: { _ in
            throw TemplateRegistry.FetchError.notFound
        })
        guard case let .refused(why) = await registry.template(for: Self.template) else { Issue.record("expected refused"); return }
        #expect(why.contains("isn't on GitHub"), "\(why)")
    }

    @Test func offlineTheBuiltInCopyOnlyAtTheSamePin() async throws {
        let bundled = try #require(TemplateRegistry.bundledTemplates().first)
        let registry = TemplateRegistry(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), fetch: { _ in
            throw URLError(.notConnectedToInternet)
        })
        if case .ready = await registry.template(for: bundled) {} else { Issue.record("same pin: the built-in copy") }
        var newer = bundled
        newer.ref = String(repeating: "f", count: 40)
        guard case let .refused(why) = await registry.template(for: newer) else { Issue.record("a newer pin never gets the older copy"); return }
        #expect(why.contains("can't reach GitHub"))
        #expect(TemplateDetails.refused(why).retriesOnAppear)
    }
}

final class BodyLog: @unchecked Sendable {
    var values: [DarkmuxClient.WorkspaceBody] = []
    var ids: [UUID] = []
    func add(_ body: DarkmuxClient.WorkspaceBody) { values.append(body) }
}
