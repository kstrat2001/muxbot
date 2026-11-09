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
        // A reload or a new page while a chip is attached: outline its
        // element again once the page is there (gone: no outline).
        let page = page
        markWatch = Task { [weak self] in
            do {
                for try await event in page.navigations where event == .finished {
                    guard let self, let picked = self.picked else { continue }
                    await self.mark(picked)
                }
            } catch {}
        }
    }
    private var markWatch: Task<Void, Never>?

    /// Outlines the picked element in the page while its chip is attached.
    private func mark(_ element: PickedElement) async {
        _ = try? await page.callJavaScript("return window.__muxMark ? window.__muxMark(sel) : false", arguments: ["sel": element.selector])
    }
    private(set) var loadedURL: URL?
    /// Pick mode: hover highlights, a click picks an element.
    private(set) var isPicking = false
    /// The element your next message is about; cleared once sent.
    var picked: PickedElement?
    /// A snapshot cropped to the picked element.
    var pickedCrop: Data?
    /// Pixels per point of the screen the preview is on, set by the views
    /// that show it; every copy is made at this scale.
    var displayScale: CGFloat = 2

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
        Task {
            pickedCrop = await crop(element)
            await mark(element)
        }
    }

    /// The crop of the element in the last message sent, for its bug card.
    private(set) var lastSentCrop: Data?

    func clearPick() {
        if picked != nil { lastSentCrop = pickedCrop }
        if picked != nil { Task { _ = try? await page.callJavaScript("if (window.__muxUnmark) window.__muxUnmark(); return true;") } }
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

    /// Loads the page again (after a run changed files): what the preview
    /// shows is then what the dev server serves now, whether or not its
    /// hot reload reached the page.
    func reload() {
        guard loadedURL != nil else { return }
        _ = page.reload()
    }

    func facts(for terms: [String]) async -> PageFacts? {
        guard loadedURL != nil, !page.isLoading else { return nil }
        let json = try? await page.callJavaScript(BugReport.factsScript, arguments: ["terms": terms]) as? String
        return json.flatMap { try? JSONDecoder().decode(PageFacts.self, from: Data($0.utf8)) }
    }

    /// What's on screen in the preview right now (not the whole page), at
    /// the display's scale. The camera, the phone's Copy screenshot and a
    /// bug card all copy this.
    func visiblePNG(scale: CGFloat? = nil) async -> Data? {
        guard let view = await viewport() else { return nil }
        return await image(of: CGRect(x: 0, y: 0, width: view.width, height: view.height), scale: scale)
    }

    /// For a bug card without a pick: what the preview shows.
    func snapshotPNG() async -> Data? { await visiblePNG() }

    /// The picked element and a 12 pt margin, at the display's scale.
    func crop(_ element: PickedElement, scale: CGFloat? = nil) async -> Data? {
        guard let view = await viewport() else { return nil }
        return await image(of: Self.cropRect(element, scrollX: view.scrollX, scrollY: view.scrollY), scale: scale)
    }

    /// The page's scroll offset and visible size, in CSS pixels.
    private func viewport() async -> (scrollX: Double, scrollY: Double, width: Double, height: Double)? {
        guard loadedURL != nil,
              let json = try? await page.callJavaScript("return JSON.stringify([scrollX, scrollY, innerWidth, innerHeight])") as? String,
              let v = try? JSONDecoder().decode([Double].self, from: Data(json.utf8)), v.count == 4 else { return nil }
        return (v[0], v[1], v[2], v[3])
    }

    /// One snapshot path for every copy. `rect` is in the web view's own
    /// coordinates (the visible area starts at the origin whatever the
    /// scroll offset), and the export makes one pixel per point of
    /// `snapshotWidth`, so asking for the width times the display's scale
    /// gives a sharp copy.
    private func image(of rect: CGRect, scale: CGFloat?) async -> Data? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let width = Self.snapshotWidth(rect.width, scale: scale ?? displayScale)
        return try? await page.exported(as: .image(region: .rect(rect), snapshotWidth: width))
    }

    nonisolated static func snapshotWidth(_ width: CGFloat, scale: CGFloat) -> CGFloat {
        width * max(scale, 1)
    }

    /// A picked element's box in the web view's coordinates: its page
    /// position minus the scroll offset, with a 12 pt margin.
    nonisolated static func cropRect(_ element: PickedElement, scrollX: Double, scrollY: Double) -> CGRect {
        CGRect(x: Double(element.x) - scrollX - 12, y: Double(element.y) - scrollY - 12,
               width: Double(element.width) + 24, height: Double(element.height) + 24)
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
