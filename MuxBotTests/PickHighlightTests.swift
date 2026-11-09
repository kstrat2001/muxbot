#if os(macOS)
import AppKit
import SwiftUI
import Testing
import WebKit
@testable import MuxBot

/// While a pick's chip is in the bar, the preview keeps showing what was
/// picked: an outline on the element (and the selection, for a text pick),
/// redrawn after a reload or re-render, gone with the chip.
@Suite(.serialized) @MainActor
struct PickHighlightTests {
    static let html = """
        <!doctype html><html><head><style>html,body{margin:0}section{height:300px;border-bottom:1px solid #ccc}</style></head><body>
        <section id="a"><p>First section</p></section><section id="b"><p id="text">Works on phones</p></section>
        <section id="c"><p>Third</p></section><section id="d"><p>Fourth</p></section></body></html>
        """

    private func host() async throws -> (PreviewController, NSWindow) {
        let preview = PreviewController()
        // Far off every screen, so no test window shows.
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WebView(preview.page).frame(width: 400, height: 500))
        window.orderFrontRegardless()
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        preview.show(try #require(URL(string: "data:text/html;base64," + Data(Self.html.utf8).base64EncodedString())))
        try await settle(preview)
        return (preview, window)
    }

    private func settle(_ preview: PreviewController) async throws {
        for _ in 0..<100 where preview.page.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(400))
    }

    private func js(_ preview: PreviewController, _ script: String) async throws -> String {
        try await preview.page.callJavaScript(script) as? String ?? ""
    }

    /// The outline's box and the element's, in page coordinates, or "none".
    private func markAndElement(_ preview: PreviewController, _ selector: String) async throws -> (mark: String, element: String) {
        let mark = try await js(preview, """
            const m = document.querySelector('[data-muxbot-mark]');
            if (!m || m.style.display === 'none' || !m.isConnected) return 'none';
            const r = m.getBoundingClientRect();
            return [Math.round(r.left + scrollX), Math.round(r.top + scrollY), Math.round(r.width), Math.round(r.height)].join(',');
            """)
        let element = try await js(preview, """
            const e = document.querySelector('\(selector)');
            if (!e) return 'gone';
            const r = e.getBoundingClientRect();
            return [Math.round(r.left + scrollX), Math.round(r.top + scrollY), Math.round(r.width), Math.round(r.height)].join(',');
            """)
        return (mark, element)
    }

    private func pick(_ preview: PreviewController, _ selector: String) async throws {
        _ = try await preview.page.callJavaScript("window.__muxSend(window.__muxDescribe(document.querySelector('\(selector)'))); return true;")
        for _ in 0..<40 where preview.picked == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test func thePickedElementStaysOutlinedWhileItsChipIsAttached() async throws {
        let (preview, window) = try await host()
        defer { window.close() }
        try await pick(preview, "#b")
        let selector = try #require(preview.picked?.selector)
        var now = try await markAndElement(preview, selector)
        #expect(now.mark != "none", "outlined while the chip is attached")
        #expect(now.mark == now.element, "on the element: \(now)")
        // Scrolling keeps it on the element.
        _ = try await preview.page.callJavaScript("window.scrollTo(0, 250); return true;")
        try await Task.sleep(for: .milliseconds(200))
        now = try await markAndElement(preview, selector)
        #expect(now.mark == now.element, "still on it after scrolling: \(now)")
        // Removing the chip (or sending the message) clears it.
        preview.clearPick()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await markAndElement(preview, selector).mark == "none")
    }

    @Test func aReloadRedrawsItOnTheSameElement() async throws {
        let (preview, window) = try await host()
        defer { window.close() }
        try await pick(preview, "#c")
        let selector = try #require(preview.picked?.selector)
        preview.reload()
        try await settle(preview)
        try await Task.sleep(for: .milliseconds(400))
        let now = try await markAndElement(preview, selector)
        #expect(now.mark != "none" && now.mark == now.element, "redrawn after the reload: \(now)")
    }

    @Test func aReRenderMovesItAndAGoneElementDropsItQuietly() async throws {
        let (preview, window) = try await host()
        defer { window.close() }
        try await pick(preview, "#c")
        let selector = try #require(preview.picked?.selector)
        // A re-render that moves the element down (what HMR does).
        _ = try await preview.page.callJavaScript("document.querySelector('#a').style.height = '500px'; return true;")
        try await Task.sleep(for: .milliseconds(300))
        var now = try await markAndElement(preview, selector)
        #expect(now.mark == now.element, "follows the element: \(now)")
        _ = try await preview.page.callJavaScript("document.querySelector('#c').remove(); return true;")
        try await Task.sleep(for: .milliseconds(300))
        now = try await markAndElement(preview, selector)
        #expect(now.mark == "none", "no outline for an element that's gone")
        #expect(preview.picked != nil, "the chip stays; nothing is said")
    }

    @Test func aTextPickKeepsItsSelection() async throws {
        let (preview, window) = try await host()
        defer { window.close() }
        _ = try await preview.page.callJavaScript("""
            const r = document.createRange(); r.selectNodeContents(document.querySelector('#text'));
            const s = getSelection(); s.removeAllRanges(); s.addRange(r);
            return true;
            """)
        try await Task.sleep(for: .milliseconds(200))
        _ = try await preview.page.callJavaScript("""
            const b = [...document.querySelectorAll('button')].find(b => b.textContent === 'Chat about this');
            b.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
            return true;
            """)
        for _ in 0..<40 where preview.picked == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(preview.picked?.selectedText == "Works on phones")
        let selected = try await js(preview, "return getSelection().toString();")
        #expect(selected == "Works on phones", "the selection stays, so you keep your place")
    }
}
#endif
