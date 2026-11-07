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
