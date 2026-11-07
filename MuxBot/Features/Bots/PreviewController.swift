import Foundation
import WebKit

/// Owns the preview's web page so bots can read facts from it and take a
/// snapshot, while the panel shows it.
@MainActor @Observable
final class PreviewController: PageInspecting {
    let page: WebPage
    private let relay = PickRelay()

    init() {
        // The page posts picks to the app the moment they happen; the
        // selection menu script is installed on every load.
        var config = WebPage.Configuration()
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: BugReport.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        scripts.add(relay, name: BugReport.handlerName)
        config.userContentController = scripts
        page = WebPage(configuration: config)
        relay.onPick = { [weak self] element in self?.received(element) }
    }
    private(set) var loadedURL: URL?
    /// Pick mode: hover highlights, a click picks an element.
    private(set) var isPicking = false
    /// The element your next message is about; cleared once sent.
    var picked: PickedElement?
    /// A snapshot cropped to the picked element.
    var pickedCrop: Data?

    func togglePicking() {
        isPicking.toggle()
        Task { _ = try? await page.callJavaScript(isPicking ? BugReport.pickerScript : BugReport.cancelPickScript) }
    }

    /// A pick or a menu choice the page just posted.
    private func received(_ element: PickedElement) {
        isPicking = false
        picked = element
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "checkPagePick") {
            try? element.selector.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muxbot-pick.txt"), atomically: true, encoding: .utf8)
        }
        #endif
        let rect = CGRect(x: element.x - 12, y: element.y - 12, width: element.width + 24, height: element.height + 24)
        Task { pickedCrop = try? await page.exported(as: .image(region: .rect(rect))) }
    }

    /// The crop of the element in the last message sent, for its bug card.
    private(set) var lastSentCrop: Data?

    func clearPick() {
        if picked != nil { lastSentCrop = pickedCrop }
        picked = nil
        pickedCrop = nil
    }

    func show(_ url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        _ = page.load(URLRequest(url: url))
        #if DEBUG
        // `-checkPagePick YES`: once loaded, pick the first heading from inside
        // the page, as a click would, to prove picks reach the app.
        if UserDefaults.standard.bool(forKey: "checkPagePick") {
            Task {
                while page.isLoading { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(1))
                _ = try? await page.callJavaScript("window.__muxSend(window.__muxDescribe(document.querySelector('h1') || document.body)); return true;")
            }
        }
        #endif
    }

    func facts(for terms: [String]) async -> PageFacts? {
        guard loadedURL != nil, !page.isLoading else { return nil }
        let json = try? await page.callJavaScript(BugReport.factsScript, arguments: ["terms": terms]) as? String
        return json.flatMap { try? JSONDecoder().decode(PageFacts.self, from: Data($0.utf8)) }
    }

    /// What's on screen in the preview right now (not the whole page).
    func visiblePNG() async -> Data? {
        guard loadedURL != nil,
              let json = try? await page.callJavaScript("return JSON.stringify([scrollX, scrollY, innerWidth, innerHeight])") as? String,
              let v = try? JSONDecoder().decode([Double].self, from: Data(json.utf8)), v.count == 4 else { return nil }
        return try? await page.exported(as: .image(region: .rect(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))))
    }

    func snapshotPNG() async -> Data? {
        guard loadedURL != nil else { return nil }
        return try? await page.exported(as: .image())
    }
}

/// Receives the page's posted picks (WebKit calls it on the main thread).
final class PickRelay: NSObject, WKScriptMessageHandler {
    @MainActor var onPick: ((PickedElement) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            if let element = BugReport.decodePick(message.body) { onPick?(element) }
        }
    }
}
