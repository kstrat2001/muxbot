import Foundation
import OSLog
import WebKit

/// Measures a page at several widths in an offscreen web view: the page is
/// loaded at each width and `LayoutMeasure.factsScript` reads its layout.
/// Nothing is shown and no model looks at it.
@MainActor
final class WebLayoutProbe: NSObject, LayoutProbing, WKNavigationDelegate {
    private static let log = Logger(subsystem: "com.darklyenergized.darkmuxapp", category: "measure")
    private var loaded: CheckedContinuation<Bool, Never>?

    func measure(url: URL, widths: [Int]) async -> [LayoutFacts] {
        var out: [LayoutFacts] = []
        for width in widths {
            if let facts = await measure(width: width, load: { $0.load(URLRequest(url: url)) }) { out.append(facts) }
        }
        Self.log.info("measured \(url.path, privacy: .public) at \(widths.map(String.init).joined(separator: ","), privacy: .public): \(out.count) ok")
        return out
    }

    /// Loads `html` instead of a URL (tests: no network).
    func measure(html: String, width: Int) async -> LayoutFacts? {
        await measure(width: width) { $0.loadHTMLString(html, baseURL: nil) }
    }

    private func measure(width: Int, load: (WKWebView) -> Void) async -> LayoutFacts? {
        // `device-width` means the device's screen (on iOS, the iPad's), not
        // this view: pin the page's viewport to the width being measured.
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: """
            (function () {
              var m = document.querySelector('meta[name=viewport]');
              if (!m) { m = document.createElement('meta'); m.name = 'viewport'; document.head.appendChild(m); }
              m.content = 'width=\(width), initial-scale=1, shrink-to-fit=no';
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 900), configuration: config)
        view.navigationDelegate = self
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            loaded = c
            load(view)
        }
        guard ok else { return nil }
        // A client-rendered page (Inertia, React) fills in after load: wait
        // until the body has content, up to 5 seconds, then let it settle.
        for _ in 0..<50 {
            let ready = (try? await view.callAsyncJavaScript("return document.body && document.body.children.length > 0 && document.readyState === 'complete'",
                                                              contentWorld: .page)) as? Bool
            if ready == true { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard let json = try? await view.callAsyncJavaScript(LayoutMeasure.factsScript, arguments: ["width": width],
                                                             contentWorld: .page) as? String else { return nil }
        return try? JSONDecoder().decode(LayoutFacts.self, from: Data(json.utf8))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finish(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finish(false) }
    }

    private func finish(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }
}
