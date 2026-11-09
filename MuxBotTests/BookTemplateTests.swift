import Foundation
import Testing
@testable import MuxBot

/// The MVP's second use case, "Write a book" (kstrat2001/muxbot-template-book
/// at e044900): its built-in copies match the live registry and parse under
/// schema 1, its first run fills in from the answers, and its "how should
/// it read?" examples become suggestions.
@MainActor
struct BookTemplateTests {
    @Test func theRegistryListsBothTemplatesPinned() throws {
        let entries = TemplateRegistry.bundledTemplates()
        #expect(entries.map(\.id) == ["website", "book"])
        let book = try #require(entries.first { $0.id == "book" })
        #expect(book.repo == "kstrat2001/muxbot-template-book")
        #expect(book.ref == "e044900cd94d086c841616b05ed63638aa402be4")
        #expect(book.title == "Write a book")
        #expect(book.icon == "book.closed")
    }

    @Test func theBookTemplateIsReadyUnderSchemaOne() throws {
        let files = try #require(TemplateRegistry.bundledFiles(for: "book"))
        let playbook = try #require(TemplateRegistry.check(playbook: files.playbook, preview: files.preview).playbook)
        #expect(playbook.title == "Write a book")
        #expect(playbook.animal == .owl)
        #expect(playbook.crew == [.coder])
        #expect(playbook.questions.count == 3)
        #expect(playbook.skills.map(\.name).contains("Draft a chapter"))
        #expect(playbook.persona(for: "Tides").hasPrefix("You help write Tides,"))
    }

    @Test func itsFirstRunFillsInFromTheAnswers() throws {
        let playbook = try #require(TemplateRegistry.bundledPlaybook(for: "book"))
        let task = try #require(playbook.firstRunTask(name: "Tides", purpose: "a lighthouse keeper's last winter", feel: "quiet and literary for adults"))
        #expect(task.hasPrefix("Set the book's title in book.json to Tides."))
        #expect(task.contains("The book is about a lighthouse keeper's last winter:"))
        #expect(task.contains("should read as, quiet and literary for adults:"))
        #expect(!task.contains("{"), "every placeholder filled")
        let noFeel = try #require(playbook.firstRunTask(name: "Tides", purpose: "a winter", feel: ""))
        #expect(!noFeel.contains("style-sheet"), "the voice line waits for an answer")
    }

    @Test func howItShouldReadOffersItsExamples() throws {
        let playbook = try #require(TemplateRegistry.bundledPlaybook(for: "book"))
        let q = PlaybookQuestion(playbook.questions[2])
        #expect(q.label == "Who is it for, and how should it read?")
        #expect(q.suggestions == ["warm and funny for teenagers", "plain and practical for small business owners"],
                "no dangling \"or\"")
    }

    @Test func startingABookPostsItsGreetingAndFirstRun() async throws {
        let store = TestStore.fresh()
        let brain = BotBrain()
        let playbook = try #require(TemplateRegistry.bundledPlaybook(for: "book"))
        let entry = try #require(TemplateRegistry.bundledTemplates().first { $0.id == "book" })
        var asked: DarkmuxClient.WorkspaceBody?
        brain.runs.workspaceMaker = { body in
            asked = body
            return DarkmuxClient.Workspace(workspace: "tides-1", branch: "main", created: true)
        }
        let bot = await StartProject.start(entry, playbook: playbook,
                                           answers: .init(name: "Tides", purpose: "a lighthouse keeper's last winter", style: "quiet and literary for adults"),
                                           store: store, runs: brain.runs)
        #expect(asked?.template == true)
        #expect(asked?.ref == "e044900cd94d086c841616b05ed63638aa402be4")
        #expect(bot.useCaseId == "book")
        let messages = (store.conversation(for: .bot(bot.id)).messages ?? []).sorted { $0.timestamp < $1.timestamp }
        #expect(messages.first?.content.hasPrefix("Hi, I'm Tides.") == true)
        #expect(messages.first?.content.contains("You help write") == false)
        #expect(messages.contains { $0.kind == .dispatchCard })
        #expect(bot.runs?.first?.task.hasPrefix("Set the book's title in book.json to Tides.") == true)
    }
}

/// The question form's suggestions wrap onto new lines instead of running
/// off the edge, so every example stays visible.
struct WrappingStackTests {
    @Test func suggestionsWrapWhenALineIsFull() {
        let sizes = [CGSize(width: 120, height: 28), CGSize(width: 150, height: 28), CGSize(width: 90, height: 30)]
        let rows = WrappingStack.rows(sizes: sizes, width: 300, spacing: 8)
        #expect(rows.map(\.indices) == [[0, 1], [2]])
        #expect(rows[0].width == 278)
        #expect(rows[1].height == 30)
    }

    @Test func aWideOneGetsALineOfItsOwn() {
        let rows = WrappingStack.rows(sizes: [CGSize(width: 400, height: 28), CGSize(width: 50, height: 28)], width: 300, spacing: 8)
        #expect(rows.map(\.indices) == [[0], [1]])
    }

    @Test func everythingFitsOnOneLineWhenThereIsRoom() {
        let rows = WrappingStack.rows(sizes: Array(repeating: CGSize(width: 50, height: 20), count: 4), width: 1000, spacing: 8)
        #expect(rows.count == 1)
        #expect(WrappingStack.rows(sizes: [], width: 300, spacing: 8).isEmpty)
    }
}
