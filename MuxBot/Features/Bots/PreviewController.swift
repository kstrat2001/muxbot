import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Owns the preview's web page so bots can read facts from it and take a
/// snapshot, while the panel shows it.
@MainActor @Observable
final class PreviewController: PageInspecting {
    /// The page the panel shows. Each bot gets a fresh one (`show(_:for:)`),
    /// so its history never holds another bot's preview.
    private(set) var page: WebPage
    private let relay = PickRelay()
    /// The bot whose preview `page` shows.
    private(set) var botId: UUID?

    init() {
        let home = HomeBox()
        self.home = home
        page = Self.makePage(relay: relay, home: home)
        relay.home = home
        relay.onPick = { [weak self] element in self?.received(element) }
        watchForMarks()
    }
    /// The preview's own address, for the navigation decider.
    private let home: HomeBox

    /// A page with the app's scripts: picks are posted to the app the moment
    /// they happen, and the selection menu is installed on every load. Back
    /// and forward are refused (a key or swipe must never bring back an
    /// older page, or a stopped preview's cached one).
    private static func makePage(relay: PickRelay, home: HomeBox) -> WebPage {
        var config = WebPage.Configuration()
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: BugReport.pageScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        scripts.add(relay, name: BugReport.handlerName)
        config.userContentController = scripts
        return WebPage(configuration: config, navigationDecider: PreviewNavigationDecider(home: home))
    }

    /// Shows `url` as `bot`'s preview. Another bot's preview gets a fresh
    /// page: no history, no pick and no page from the bot before.
    func show(_ url: URL, for bot: UUID?) {
        if bot != botId {
            botId = bot
            isPicking = false
            picked = nil
            pickedBot = nil
            loadedGeneration = nil
            pickedCrop = nil
            loadedURL = nil
            page = Self.makePage(relay: relay, home: home)
            watchForMarks()
            // A pick asked for this bot (its chip) waits for its page.
            if pickRequestedFor == bot { isPicking = true }
        }
        show(url)
    }

    /// A reload or a new page while a chip is attached: outline its element
    /// again once the page is there (gone: no outline). Restarted for each
    /// bot's fresh page, so it always watches the page on screen.
    private func watchForMarks() {
        markWatch?.cancel()
        let page = page
        markWatch = Task { [weak self] in
            do {
                for try await event in page.navigations where event == .finished {
                    guard !Task.isCancelled else { return }
                    guard let self, self.page === page else { continue }
                    // Pick mode survives a load (a reload, HMR, the first load
                    // after the chip): its script is put back on the new page.
                    if self.isPicking {
                        self.pickRequestedFor = nil
                        _ = try? await page.callJavaScript(BugReport.pickerScript)
                    }
                    if let picked = self.picked { await self.mark(picked) }
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

    /// Back to the preview's own page (Reload / Home): loads it again even
    /// when it's the same address, after a broken page or a link elsewhere.
    func goHome() {
        guard let loadedURL else { return }
        _ = page.load(URLRequest(url: loadedURL))
    }

    /// The bot whose chip asked for Pick before its page was there.
    private var pickRequestedFor: UUID?

    /// Pick from the chip: on as soon as `bot`'s page has loaded (now, if it
    /// already has).
    func startPicking(for bot: UUID?) {
        pickRequestedFor = bot
        isPicking = true
        guard loadedURL != nil, botId == bot, !page.isLoading else { return }
        pickRequestedFor = nil
        Task { _ = try? await page.callJavaScript(BugReport.pickerScript) }
    }

    func togglePicking() {
        isPicking.toggle()
        if !isPicking { pickRequestedFor = nil }
        Task { _ = try? await page.callJavaScript(isPicking ? BugReport.pickerScript : BugReport.cancelPickScript) }
    }

    /// A pick or a menu choice the page just posted.
    private func received(_ element: PickedElement) {
        isPicking = false
        picked = element
        pickedBot = botId
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


    /// iPhone and iPad's full-screen preview: the bot's page, recorded as
    /// its, so bugs measure it and Point at something starts there.
    func showFullScreen(_ url: URL, for bot: UUID?) { show(url, for: bot) }

    /// The bot whose page the pick was made on: the chip shows, and goes
    /// with a message, only in that bot's thread.
    var pickedBot: UUID?

    /// The pick for the thread on screen, if it was made on that bot's page.
    func pick(for context: ChatContext) -> PickedElement? {
        guard let bot = context.botId, bot == pickedBot else { return nil }
        return picked
    }

    /// The bot's preview stopped: its page is let go, so nothing (a bug,
    /// a screenshot) reads a stopped preview's page.
    func forget(_ bot: UUID) {
        guard botId == bot else { return }
        botId = nil
        isPicking = false
        picked = nil
        pickedBot = nil
        pickedCrop = nil
        loadedURL = nil
        loadedGeneration = nil
        page = Self.makePage(relay: relay, home: home)
        watchForMarks()
    }

    /// Page loads and reloads, counted (tests).
    private(set) var loads = 0
    /// The bot's `previewReloads` count its page was loaded at.
    private var loadedGeneration: Int?

    /// Shows the bot's page as of reload `generation` (`previewReloads`):
    /// one that moved on while the panel was closed is reloaded on reopen.
    func show(_ url: URL, for bot: UUID?, generation: Int) {
        let fresh = bot != botId || loadedURL != url
        show(url, for: bot)
        if !fresh, let loaded = loadedGeneration, generation > loaded { reload() }
        loadedGeneration = generation
    }

    func clearPick() {
        if picked != nil { Task { _ = try? await page.callJavaScript("if (window.__muxUnmark) window.__muxUnmark(); return true;") } }
        picked = nil
        pickedBot = nil
        pickedCrop = nil
    }

    func show(_ url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        home.url = url
        loads += 1
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
        loads += 1
        _ = page.reload()
    }

    /// Facts from `bot`'s own preview only: nil when another bot's page
    /// (or none) is the one loaded, so a bug never measures the wrong site.
    func facts(for terms: [String], bot: UUID?) async -> PageFacts? {
        guard let bot, bot == botId else { return nil }
        return await facts(for: terms)
    }

    /// A screenshot of `bot`'s own preview only.
    func snapshotPNG(bot: UUID?) async -> Data? {
        guard let bot, bot == botId else { return nil }
        return await visiblePNG()
    }

    private func facts(for terms: [String]) async -> PageFacts? {
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

/// Refuses back and forward navigations in the preview (Delete, a swipe,
/// a menu): the preview always shows the bot's current page.
struct PreviewNavigationDecider: WebPage.NavigationDeciding {
    let home: HomeBox

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        if action.navigationType == .backForward { return .cancel }
        // A link to another site opens in the browser; the preview stays put.
        if action.navigationType == .linkActivated, let url = action.request.url, let base = home.url,
           PreviewNavigation.opensElsewhere(url, home: base) {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            await UIApplication.shared.open(url)
            #endif
            return .cancel
        }
        return .allow
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy { .allow }
}

/// Receives the page's posted picks (WebKit calls it on the main thread).
/// A pick counts only when the preview's own page posted it: from the main
/// frame, on the preview's own site (`HomeBox.url`). An iframe, or a page
/// from anywhere else, can post to the handler too; those are dropped.
final class PickRelay: NSObject, WKScriptMessageHandler {
    @MainActor var onPick: ((PickedElement) -> Void)?
    /// The preview's own address.
    @MainActor var home: HomeBox?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            let frame = message.frameInfo
            let origin = frame.securityOrigin
            guard frame.isMainFrame,
                  PreviewNavigation.isPreviewOrigin(scheme: origin.`protocol`, host: origin.host, port: origin.port, home: home?.url) else { return }
            if let element = BugReport.decodePick(message.body) { onPick?(element) }
        }
    }
}

/// Where a link in the preview goes.
enum PreviewNavigation {
    /// A web address on another site (scheme, host or port) than the
    /// preview's: it opens in the browser, never inside the preview.
    static func opensElsewhere(_ url: URL, home: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return url.scheme?.lowercased() != home.scheme?.lowercased() || url.host()?.lowercased() != home.host()?.lowercased()
            || (url.port ?? defaultPort(url)) != (home.port ?? defaultPort(home))
    }

    private static func defaultPort(_ url: URL) -> Int { url.scheme?.lowercased() == "https" ? 443 : 80 }

    /// Whether an origin (as WebKit reports a frame's: scheme, host, and a
    /// port of 0 for the scheme's own) is the preview's own page's.
    static func isPreviewOrigin(scheme: String, host: String, port: Int, home: URL?) -> Bool {
        guard let home, let homeScheme = home.scheme?.lowercased() else { return false }
        let scheme = scheme.lowercased()
        let web = ["http", "https"]
        // A page with no site of its own (a data: page) has no host to
        // compare: its picks count only while no web site is showing.
        guard web.contains(homeScheme) else { return !web.contains(scheme) && host.isEmpty }
        guard let homeHost = home.host()?.lowercased() else { return false }
        let usual = scheme == "https" ? 443 : 80
        return scheme == homeScheme && host.lowercased() == homeHost
            && (port == 0 ? usual : port) == (home.port ?? defaultPort(home))
    }
}

/// The preview's address, read by its navigation decider.
@MainActor final class HomeBox {
    var url: URL?
}
