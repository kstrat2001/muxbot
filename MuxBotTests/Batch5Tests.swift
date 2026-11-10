import Foundation
import SwiftData
import Testing
@testable import MuxBot

@Suite(.serialized) @MainActor
struct BotEditingTests {
    @Test func deletingABotRemovesItsThreadRunsAndLocalState() throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "Site")
        let keep = store.add(name: "other", instructions: "Other")
        store.addResource(.repo, "https://github.com/a/b", to: bot)
        store.proposeRun(task: "x", crew: .coder, on: bot)
        store.append(.user, "hi", to: store.conversation(for: .bot(bot.id)))
        bot.workspaceName = "site-ws"
        let id = bot.id
        store.delete(bot)
        #expect(store.allBots().map(\.name) == ["other"])
        #expect(try store.context.fetch(FetchDescriptor<BotRun>()).isEmpty)
        #expect(try store.context.fetch(FetchDescriptor<BotResource>()).isEmpty)
        #expect(try store.context.fetch(FetchDescriptor<ChatConversation>()).allSatisfy { $0.roleId != id })
        #expect(LocalBotState.shared[id] == nil)
        #expect(keep.name == "other")
    }

    @Test func clearingAConversationKeepsTheBotAndItsRuns() throws {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "Site")
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        store.append(.user, "hi", to: store.conversation(for: .bot(bot.id)))
        store.clearConversation(.bot(bot.id))
        // Sweep batch 2: the waiting dispatch card stays so it can still be
        // decided; everything else goes.
        #expect((store.conversation(for: .bot(bot.id)).messages ?? []).map(\.runId) == [run.id])
        #expect(store.run(id: run.id) != nil, "runs stay in Activity")
    }
}

struct DiffLineTests {
    @Test(arguments: [
        ("+added", DiffLine.Kind.added), ("-removed", .removed), ("@@ -1,2 +1,2 @@", .hunk),
        ("+++ b/file", .meta), ("--- a/file", .meta), ("diff --git a/x b/x", .meta), (" context", .context),
    ])
    func linesAreClassified(line: String, kind: DiffLine.Kind) {
        #expect(DiffLine.kind(of: line) == kind)
    }
}

@Suite(.serialized) @MainActor
struct RunNoticeTests {
    @Test func aResultAndAFailureReadPlainly() {
        let store = TestStore.fresh()
        let bot = store.add(name: "humancodereader", instructions: "Site")
        let run = store.proposeRun(task: "Fix #8: gutter", crew: .coder, on: bot)
        store.apply(.approve, to: run)
        store.apply(.finish(summary: "I restored the side padding."), to: run)
        #expect(RunNotice.make(for: run) == RunNotice(title: "humancodereader: result ready", body: "Fix #8: gutter. I restored the side padding."))
        let failed = store.proposeRun(task: "Fix #9", crew: .coder, on: bot)
        store.apply(.approve, to: failed)
        store.apply(.fail(reason: "Didn't finish: out of time", details: nil), to: failed)
        #expect(RunNotice.make(for: failed) == RunNotice(title: "humancodereader: didn't finish", body: "Fix #9. Didn't finish: out of time"))
        let running = store.proposeRun(task: "x", crew: .coder, on: bot)
        #expect(RunNotice.make(for: running) == nil, "only results and failures notify")
    }

    @Test func theBadgeCountsWhatWaitsOnYou() {
        let store = TestStore.fresh()
        let bot = store.add(name: "b", instructions: "B")
        let a = store.proposeRun(task: "a", crew: .coder, on: bot)        // proposed: waits
        let b = store.proposeRun(task: "b", crew: .coder, on: bot)
        store.apply(.approve, to: b)                                       // running: no
        let c = store.proposeRun(task: "c", crew: .coder, on: bot)
        store.apply(.cancel, to: c)                                        // closed: no
        #expect(RunNotice.badgeCount([a, b, c]) == 1)
    }
}

@Suite(.serialized) @MainActor
struct SearchTests {
    @Test func searchFindsBotsAndMessages() {
        let store = TestStore.fresh()
        let site = store.add(name: "humancodereader", instructions: "The website")
        let brand = store.add(name: "Personal brand", instructions: "Posts on X")
        store.append(.user, "the pricing gutter is gone", to: store.conversation(for: .bot(site.id)))
        store.append(.assistant, "Posts drafted", to: store.conversation(for: .bot(brand.id)))
        // Cards (here a dispatch card's title) aren't messages you search for.
        store.proposeRun(task: "Fix the pricing gutter", crew: .coder, on: site)
        let hits = SearchResults.find("PRICING", bots: store.allBots(), messages: (try? store.context.fetch(FetchDescriptor<ChatMessage>())) ?? [])
        #expect(hits.bots.isEmpty)
        #expect(hits.messages.map(\.content) == ["the pricing gutter is gone"])
        #expect(SearchResults.find("posts", bots: store.allBots(), messages: []).bots.map(\.name) == ["Personal brand"])
        #expect(SearchResults.find("  ", bots: store.allBots(), messages: []).isEmpty)
    }
}
