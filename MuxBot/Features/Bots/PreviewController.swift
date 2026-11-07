import Foundation
import WebKit

/// Owns the preview's web page so bots can read facts from it and take a
/// snapshot, while the panel shows it.
@MainActor @Observable
final class PreviewController: PageInspecting {
    let page = WebPage()
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

    /// While a page is shown, keep the selection menu installed and collect
    /// anything picked or chosen from it.
    private func watch() async {
        while loadedURL != nil {
            try? await Task.sleep(for: .milliseconds(300))
            guard !page.isLoading,
                  let json = try? await page.callJavaScript(BugReport.ensureScript) as? String,
                  let element = try? JSONDecoder().decode(PickedElement.self, from: Data(json.utf8)) else { continue }
            isPicking = false
            picked = element
            let rect = CGRect(x: element.x - 12, y: element.y - 12, width: element.width + 24, height: element.height + 24)
            pickedCrop = try? await page.exported(as: .image(region: .rect(rect)))
        }
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
        let first = loadedURL == nil
        loadedURL = url
        _ = page.load(URLRequest(url: url))
        if first { Task { await watch() } }
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
