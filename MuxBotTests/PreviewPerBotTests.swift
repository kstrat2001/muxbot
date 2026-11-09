#if os(macOS)
import AppKit
import SwiftUI
import Testing
import WebKit
@testable import MuxBot

/// Each bot's preview starts from a clean history, so no key, swipe or back
/// navigation can show another bot's page (Kain: Delete in the "test book"
/// thread went back to test-3's website).
@Suite(.serialized) @MainActor
struct PreviewPerBotTests {
    private func page(_ title: String) -> URL {
        URL(string: "data:text/html;base64," + Data("<!doctype html><title>\(title)</title><body><p>\(title)</p><input id=f></body>".utf8).base64EncodedString())!
    }

    private func host(_ preview: PreviewController) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreviewHost(preview: preview))
        window.orderFrontRegardless()
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        return window
    }

    /// Like the panel: it draws whichever page the controller has now.
    struct PreviewHost: View {
        let preview: PreviewController
        var body: some View { WebView(preview.page).frame(width: 400, height: 400) }
    }

    private func settle(_ preview: PreviewController) async throws {
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<100 where preview.page.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
    }

    private func title(_ preview: PreviewController) async throws -> String {
        try await preview.page.callJavaScript("return document.title") as? String ?? ""
    }

    @Test func switchingBotsLeavesNoHistoryFromTheOtherBot() async throws {
        let preview = PreviewController()
        let window = host(preview)
        defer { window.close() }
        let site = UUID(), book = UUID()
        preview.show(page("Site home"), for: site)
        try await settle(preview)
        preview.show(page("Site about"), for: site)
        try await settle(preview)
        #expect(!preview.page.backForwardList.backList.isEmpty, "the site's own history")
        preview.show(page("Book"), for: book)
        try await settle(preview)
        #expect(preview.page.backForwardList.backList.isEmpty, "nothing from the site behind the book")
        #expect(try await title(preview) == "Book")
    }

    @Test func theSameBotKeepsItsPage() async throws {
        let preview = PreviewController()
        let window = host(preview)
        defer { window.close() }
        let site = UUID()
        preview.show(page("Site home"), for: site)
        let first = ObjectIdentifier(preview.page)
        preview.show(page("Site about"), for: site)
        #expect(ObjectIdentifier(preview.page) == first)
    }

    @Test func backAndForwardAreRefused() async throws {
        let preview = PreviewController()
        let window = host(preview)
        defer { window.close() }
        let site = UUID()
        preview.show(page("First"), for: site)
        try await settle(preview)
        preview.show(page("Second"), for: site)
        try await settle(preview)
        let back = try #require(preview.page.backForwardList.backList.last)
        _ = preview.page.load(back)
        try await settle(preview)
        #expect(try await title(preview) == "Second", "a back navigation never happens")
    }

    @Test func deleteOutsideATextFieldDoesNothing() async throws {
        let preview = PreviewController()
        let window = host(preview)
        defer { window.close() }
        preview.show(page("Site"), for: UUID())
        try await settle(preview)
        let onPage = try await preview.page.callJavaScript("""
            const e = new KeyboardEvent('keydown', { key: 'Backspace', bubbles: true, cancelable: true });
            document.body.dispatchEvent(e); return e.defaultPrevented;
            """) as? Bool
        #expect(onPage == true, "Delete on the page is swallowed, so WebKit can't go back")
        let inField = try await preview.page.callJavaScript("""
            const f = document.getElementById('f'); f.focus();
            const e = new KeyboardEvent('keydown', { key: 'Backspace', bubbles: true, cancelable: true });
            f.dispatchEvent(e); return e.defaultPrevented;
            """) as? Bool
        #expect(inField == false, "typing in the page's own fields still works")
    }

    @Test func switchingBotsDropsTheOtherBotsPick() async throws {
        let preview = PreviewController()
        let window = host(preview)
        defer { window.close() }
        preview.show(page("Site"), for: UUID())
        preview.picked = PickedElement.fixture
        preview.show(page("Book"), for: UUID())
        #expect(preview.picked == nil)
    }
}
#endif
