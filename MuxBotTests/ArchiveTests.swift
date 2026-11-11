import Foundation
import SwiftData
import Testing
@testable import MuxBot

/// Archive instead of delete: a bot leaves the lists with everything kept
/// and comes back as it was; Clear Conversation can be undone.
@Suite(.serialized) @MainActor
struct ArchiveTests {
    @Test func archivingKeepsTheThreadAndRunsAndRestoreBringsItBack() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "Site")
        let other = store.add(name: "book", instructions: "Book")
        store.append(.user, "make the header blue", to: store.conversation(for: .bot(bot.id)))
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        store.apply(.cancel, to: run)

        store.archive(bot)
        #expect(bot.isArchived)
        #expect(store.activeBots().map(\.id) == [other.id])
        #expect(store.archivedBots().map(\.id) == [bot.id])
        #expect(store.run(id: run.id) != nil, "runs are kept")
        #expect((store.conversation(for: .bot(bot.id)).messages ?? []).contains { $0.content == "make the header blue" })

        store.restore(bot)
        #expect(!bot.isArchived)
        #expect(Set(store.activeBots().map(\.id)) == [bot.id, other.id])
    }

    @Test func openWorkBlocksArchiving() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "Site")
        #expect(BotStore.archiveBlocker(bot) == nil)
        let run = store.proposeRun(task: "x", crew: .coder, on: bot)
        #expect(BotStore.archiveBlocker(bot) != nil, "a dispatch waiting for Approve")
        store.apply(.approve, to: run)
        #expect(BotStore.archiveBlocker(bot) != nil, "a run going")
        store.apply(.stop, to: run)
        #expect(BotStore.archiveBlocker(bot) == nil)
    }

    @Test func clearConversationCanBeUndone() {
        let store = TestStore.fresh()
        let bot = store.add(name: "site", instructions: "Site")
        let thread = store.conversation(for: .bot(bot.id))
        store.append(.user, "first", to: thread)
        store.append(.assistant, "second", to: thread)
        let before = (thread.messages ?? []).sorted { $0.timestamp < $1.timestamp }.map { [$0.id.uuidString, $0.content] }

        let cleared = store.clearConversation(.bot(bot.id))
        #expect((store.conversation(for: .bot(bot.id)).messages ?? []).isEmpty)

        store.undoClear(cleared)
        store.undoClear(cleared)   // twice changes nothing
        let after = (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }
            .map { [$0.id.uuidString, $0.content] }
        #expect(after == before)
    }
}
