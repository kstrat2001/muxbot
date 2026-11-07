import Foundation
import WebKit

/// Owns the preview's web page so bots can read facts from it and take a
/// snapshot, while the panel shows it.
@MainActor @Observable
final class PreviewController: PageInspecting {
    let page = WebPage()
    private(set) var loadedURL: URL?

    func show(_ url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        _ = page.load(URLRequest(url: url))
    }

    func facts(for terms: [String]) async -> PageFacts? {
        guard loadedURL != nil, !page.isLoading else { return nil }
        let json = try? await page.callJavaScript(BugReport.factsScript, arguments: ["terms": terms]) as? String
        return json.flatMap { try? JSONDecoder().decode(PageFacts.self, from: Data($0.utf8)) }
    }

    func snapshotPNG() async -> Data? {
        guard loadedURL != nil else { return nil }
        return try? await page.exported(as: .image())
    }
}
