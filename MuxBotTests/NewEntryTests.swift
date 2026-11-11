import Foundation
import Testing
@testable import MuxBot

/// One way in: "New" (sidebar, Home's +, File › New… ⌘N) opens "What do you
/// want to get done?", with templates first, then your own project, then a
/// bot with no project last.
struct NewEntryTests {
    @Test func theEntryIsCalledNew() {
        #expect(NewEntry.rowTitle == "New")
        #expect(NewEntry.menuTitle == "New…")
    }

    @Test func theChooserPutsJustABotLast() {
        #expect(StartChoice.order(templateIds: ["website", "book"]) == [.template("website"), .template("book"), .existing, .justABot])
        #expect(StartChoice.order(templateIds: []) == [.existing, .justABot], "still a way in while templates load")
        #expect(StartChoice.justABotTitle == "Just a bot, no project")
    }
}
