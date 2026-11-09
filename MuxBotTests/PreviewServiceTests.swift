import Foundation
import Testing
@testable import MuxBot

struct PreviewServiceTests {
    private let resource = URL(string: "http://example.test:8445/")!
    private let darkmux = URL(string: "http://127.0.0.1:51234/")!

    @Test func darkmuxsReadyPreviewWins() {
        let ready = LivePreview(status: .ready, url: darkmux)
        #expect(LivePreview.url(darkmux: ready, resource: resource) == darkmux)
    }

    @Test func whileItStartsTheresNoURLYet() {
        for status in [LivePreview.Status.starting, .installing, .failed("boom")] {
            #expect(LivePreview.url(darkmux: LivePreview(status: status, url: darkmux), resource: resource) == nil)
        }
    }

    @Test func withoutDarkmuxYourLinkIsUsed() {
        #expect(LivePreview.url(darkmux: nil, resource: resource) == resource)
        #expect(LivePreview.url(darkmux: LivePreview(status: .stopped, url: darkmux), resource: resource) == resource)
    }

    @Test func statusInPlainWords() {
        #expect(LivePreview.Status.starting.text == "Starting the preview…")
        #expect(LivePreview.Status.installing.text == "Installing the project's dependencies (first time only)…")
        #expect(LivePreview.Status.failed("the dev server exited (exit status: 1)").text
                == "The preview didn't start: the dev server exited (exit status: 1).")
    }

    @Test func darkmuxsReplyDecodes() throws {
        let json = #"{"workspace":"hcr","status":"failed","url":"http://127.0.0.1:5000/","port":5000,"hmr_port":5001,"error":"exited","log_tail":"boom"}"#
        let p = try JSONDecoder().decode(DarkmuxClient.Preview.self, from: Data(json.utf8))
        #expect(p.live == LivePreview(status: .failed("exited"), url: URL(string: "http://127.0.0.1:5000/")!, log: "boom"))
        let ready = try JSONDecoder().decode(DarkmuxClient.Preview.self, from: Data(#"{"status":"ready","url":"http://127.0.0.1:5000/"}"#.utf8))
        #expect(ready.live.status == .ready)
    }
}

/// At launch the darkmux connection isn't attached yet: the preview says it's
/// waiting (never a blank panel) and starts once the connection appears.
@Suite(.serialized) @MainActor
struct PreviewWaitingTests {
    @Test func withoutTheConnectionThePreviewSaysItsWaiting() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        bot.workspaceName = "hcr-test"
        let runs = RunCoordinator()
        await runs.ensurePreview(for: bot)
        #expect(runs.livePreviews[bot.id]?.status == .waiting)
        #expect(LivePreview.Status.waiting.text == "Waiting for darkmux…")
        #expect(LivePreview.url(darkmux: runs.livePreviews[bot.id], resource: URL(string: "http://example.test/")) == nil)
        bot.workspaceName = nil
    }

    @Test func theConnectionAppearingRetriesWaitingPreviews() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        bot.workspaceName = "hcr-test"
        let runs = RunCoordinator()
        await runs.ensurePreview(for: bot)
        var retried: [UUID] = []
        runs.retryPreview = { retried.append($0.id) }
        runs.connectionAttached()
        await Task.yield()
        #expect(retried == [bot.id])
        bot.workspaceName = nil
    }

    @Test func aBotWithoutAWorkCopyHasNothingToWaitFor() async {
        let store = TestStore.fresh()
        let bot = store.add(name: "hcr", instructions: "Site")
        let runs = RunCoordinator()
        await runs.ensurePreview(for: bot)
        #expect(runs.livePreviews[bot.id] == nil)
    }
}
