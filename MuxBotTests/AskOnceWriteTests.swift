import Foundation
import Testing
@testable import MuxBot

/// Writing into your checkout asks once, when you add the folder: Add folder
/// keeps a read-write bookmark, so Approve on a setup card writes with no
/// picker. A bot added before (a read-only bookmark) asks once more, on that
/// same folder only, and is upgraded. Writes stay new-file-only.
@Suite(.serialized) @MainActor
struct AskOnceWriteTests {
    private let checkout = URL(fileURLWithPath: "/tmp/de-projects/hcr")

    private func bot(_ store: BotStore) -> Bot {
        let bot = store.add(name: "hcr", instructions: "")
        bot.folderBookmark = Data("old".utf8)
        bot.folderName = "hcr"
        return bot
    }

    private func deps(writes: @escaping (URL) throws(PreviewSetup.WriteError) -> Void, asked: @escaping (URL?) -> URL?) -> CheckoutWrite.Deps {
        CheckoutWrite.Deps(resolve: { _ in checkout }, write: { _, _, folder throws(PreviewSetup.WriteError) in try writes(folder) },
                           ask: asked, bookmark: { _ in Data("new".utf8) })
    }

    @Test func aWritableBookmarkWritesWithNoPicker() {
        let store = TestStore.fresh(); let bot = bot(store)
        var asked = false
        let why = CheckoutWrite.perform(Data(), at: PreviewSetup.path, bot: bot,
                                        deps: deps(writes: { _ in }, asked: { _ in asked = true; return nil }))
        #expect(why == nil)
        #expect(!asked, "no folder picker once the folder was added")
    }

    @Test func aReadOnlyBookmarkAsksOnceOnThatFolderAndIsUpgraded() {
        let store = TestStore.fresh(); let bot = bot(store)
        var tries = 0
        var openedOn: URL?
        let why = CheckoutWrite.perform(Data(), at: PreviewSetup.path, bot: bot, deps: deps(writes: { _ throws(PreviewSetup.WriteError) in
            tries += 1
            if tries == 1 { throw .noPermission }
        }, asked: { start in openedOn = start; return checkout }))
        #expect(why == nil)
        #expect(openedOn == checkout, "the panel opens on the bot's folder itself")
        #expect(bot.folderBookmark == Data("new".utf8), "kept read-write from now on")
    }

    @Test func aDifferentFolderIsRefusedAndNothingIsWritten() {
        let store = TestStore.fresh(); let bot = bot(store)
        var tries = 0
        let why = CheckoutWrite.perform(Data(), at: PreviewSetup.path, bot: bot, deps: deps(writes: { _ throws(PreviewSetup.WriteError) in
            tries += 1
            throw .noPermission
        }, asked: { _ in URL(fileURLWithPath: "/tmp/de-projects/other") }))
        #expect(why == "That's a different folder from the one hcr uses. Pick hcr.")
        #expect(tries == 1, "nothing written into the other folder")
        #expect(bot.folderBookmark == Data("old".utf8))
    }

    @Test func aFileThatsThereIsNeverOverwrittenOrAskedAbout() {
        let store = TestStore.fresh(); let bot = bot(store)
        var asked = false
        let why = CheckoutWrite.perform(Data(), at: PreviewSetup.path, bot: bot, deps: deps(writes: { _ throws(PreviewSetup.WriteError) in
            throw .exists
        }, asked: { _ in asked = true; return checkout }))
        #expect(why == PreviewSetup.WriteError.exists.localizedDescription)
        #expect(!asked)
    }

    #if os(macOS)
    @Test func addFolderKeepsAReadWriteBookmark() {
        #expect(!CheckoutWrite.bookmarkOptions.contains(.securityScopeAllowOnlyReadAccess))
        #expect(CheckoutWrite.bookmarkOptions.contains(.withSecurityScope))
    }
    #endif

    /// A folder the app may only read says so, so the write can ask once.
    @Test func aRefusedWriteIsNoPermission() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        #expect(throws: PreviewSetup.WriteError.noPermission) { try PreviewSetup.writeNew(Data("x".utf8), at: "a.txt", into: dir) }
    }
}
