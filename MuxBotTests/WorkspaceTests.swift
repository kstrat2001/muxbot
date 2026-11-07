import Foundation
import SwiftData
import Testing
@testable import MuxBot

/// Reading a picked folder's GitHub repo from its git config, without git.
struct GitRemoteTests {
    private func folder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let config = """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = https://github.com/someone-else/fork.git
        [remote "origin"]
        \turl = %@
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """

    @Test(arguments: [
        ("git@github.com:kstrat2001/hcr.git", "kstrat2001/hcr"),
        ("https://github.com/kstrat2001/hcr", "kstrat2001/hcr"),
        ("https://github.com/kstrat2001/hcr.git", "kstrat2001/hcr"),
    ])
    func originOfACheckout(url: String, slug: String) throws {
        let dir = try folder([".git/config": String(format: config, url)])
        #expect(GitRemote.originSlug(of: dir) == slug)
        #expect(GitRemote.isRepository(dir))
    }

    @Test func aWorktreeFollowsItsGitdirToTheSharedConfig() throws {
        let dir = try folder([
            "main/.git/config": String(format: config, "git@github.com:kstrat2001/hcr.git"),
            "main/.git/worktrees/wt/commondir": "../..\n",
            "wt/.git": "gitdir: ../main/.git/worktrees/wt\n",
        ])
        #expect(GitRemote.originSlug(of: dir.appendingPathComponent("wt")) == "kstrat2001/hcr")
    }

    @Test func aPlainFolderIsNotARepository() throws {
        let dir = try folder(["notes.txt": "hi"])
        #expect(!GitRemote.isRepository(dir))
        #expect(GitRemote.originSlug(of: dir) == nil)
    }

    @Test func aNonGitHubOriginHasNoSlug() throws {
        let dir = try folder([".git/config": String(format: config, "git@gitlab.com:me/site.git")])
        #expect(GitRemote.isRepository(dir))
        #expect(GitRemote.originSlug(of: dir) == nil)
    }
}

@Suite(.serialized) @MainActor
struct WorkCopyTests {
    @Test func anOldWorkFolderBecomesAWorkspaceName() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Website")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: bot)
        store.addResource(.folder, "~/.darkmux/worktrees/hcr-preview", to: bot)
        store.addResource(.previewURL, "http://example.test:8445/", to: bot)
        store.migrateWorkCopies(machine: "MacBook Pro")
        #expect(bot.workspaceName == "hcr-preview")
        #expect(bot.workspaceMachine == "MacBook Pro")
        #expect(!bot.sortedResources.contains { $0.kind == .folder })
        #expect(bot.sortedResources.contains { $0.kind == .previewURL }, "your own preview link stays")
        // Idempotent.
        store.migrateWorkCopies(machine: "MacBook Pro")
        #expect(bot.workspaceName == "hcr-preview")
    }

    @Test func whatBlocksARun() {
        let store = TestStore.fresh()
        let bare = store.add(name: "Personal brand", instructions: "Posts")
        let repo = store.add(name: "hcr", instructions: "Site")
        store.addResource(.repo, "https://github.com/kstrat2001/hcr", to: repo)
        let ready = store.add(name: "ready", instructions: "Site")
        ready.workspaceName = "hcr-preview"
        #expect(RunBlocker.check(paired: false, crew: .coder, bot: repo, deviceRuns: true) == .unpaired)
        #expect(RunBlocker.check(paired: true, crew: .evalRunner, bot: repo, deviceRuns: true) == .noRole("Eval runner"))
        #expect(RunBlocker.check(paired: true, crew: .coder, bot: bare, deviceRuns: true) == .noCode)
        #expect(RunBlocker.check(paired: true, crew: .coder, bot: repo, deviceRuns: true) == .needsWorkCopy("kstrat2001/hcr"))
        #expect(RunBlocker.check(paired: true, crew: .coder, bot: ready, deviceRuns: true) == nil)
    }

    @Test func aPickedFolderIsAWorkCopySourceToo() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "Site")
        bot.folderBookmark = Data([1, 2, 3])
        bot.folderName = "site"
        #expect(RunBlocker.check(paired: true, crew: .coder, bot: bot, deviceRuns: true) == .needsWorkCopy("site"))
    }

    @Test func foldersAreAddedWithTheOpenPanelNotTyped() {
        #expect(!ResourceKind.addable.contains(.folder))
        #expect(ResourceKind.addable.contains(.repo))
    }
}

struct WorkspaceRequestTests {
    private func json(_ body: some Encodable) throws -> [String: String] {
        let data = try JSONEncoder().encode(body)
        return try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]
    }

    @Test func aRepoOrAFolderAndTheBotName() throws {
        #expect(try json(DarkmuxClient.WorkspaceBody(repoURL: "https://github.com/kstrat2001/hcr", sourcePath: nil, bot: "humancodereader"))
                == ["repo_url": "https://github.com/kstrat2001/hcr", "bot": "humancodereader"])
        #expect(try json(DarkmuxClient.WorkspaceBody(repoURL: nil, sourcePath: "/Users/me/site", bot: "site"))
                == ["source_path": "/Users/me/site", "bot": "site"])
    }

    @Test func workNamesTheWorkspaceNotAPath() throws {
        #expect(try json(DarkmuxClient.WorkBody(role: "coder", message: "m", profile: nil, workspace: "hcr-preview"))
                == ["role": "coder", "message": "m", "workspace": "hcr-preview"])
    }
}
