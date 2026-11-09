#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import Testing
import WebKit
@testable import MuxBot

/// The camera's copy is exactly what the preview shows: the scrolled-to part
/// of the page (not one scroll offset further down), the web view's whole
/// visible size, at the display's scale (not blurry). Checked on a real web
/// view in a window, on a page of colored bands.
@Suite(.serialized) @MainActor
struct VisiblePreviewTests {
    /// 200px bands, each its own color.
    static let bands: [(r: Int, g: Int, b: Int)] = [
        (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0), (255, 0, 255),
        (0, 255, 255), (128, 0, 0), (0, 128, 0), (0, 0, 128), (128, 128, 0),
    ]

    static var html: String {
        let divs = bands.map { "<div style=\"height:200px;background:rgb(\($0.r),\($0.g),\($0.b))\"></div>" }.joined()
        return "<!doctype html><html><head><style>html,body{margin:0;padding:0;overflow-x:hidden}::-webkit-scrollbar{display:none}</style></head><body>\(divs)</body></html>"
    }

    /// A window showing the page at `size`, laid out like the panel's device
    /// frame (`scale` < 1 is phone or tablet size in a small panel).
    private func host(_ preview: PreviewController, size: CGSize, scale: CGFloat) async throws -> NSWindow {
        let content = WebView(preview.page)
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: content)
        window.orderFrontRegardless()
        preview.show(try #require(URL(string: "data:text/html;base64," + Data(Self.html.utf8).base64EncodedString())))
        for _ in 0..<100 where preview.page.isLoading || preview.page.url == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300))
        return window
    }

    private func scroll(_ preview: PreviewController, to y: Int) async throws {
        _ = try await preview.page.callJavaScript("window.scrollTo(0, \(y)); return true;")
        try await Task.sleep(for: .milliseconds(300))
    }

    private func image(_ png: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The band showing at `y` points down the copy.
    private func band(in image: CGImage, atPoint y: CGFloat, pointHeight: CGFloat) -> Int? {
        let row = Int(y / pointHeight * CGFloat(image.height))
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height - 1 - row), width: CGFloat(image.width), height: CGFloat(image.height)))
        let p = context.data!.assumingMemoryBound(to: UInt8.self)
        let (r, g, b) = (Int(p[0]), Int(p[1]), Int(p[2]))
        return Self.bands.firstIndex { abs($0.r - r) < 40 && abs($0.g - g) < 40 && abs($0.b - b) < 40 }
    }

    @Test(arguments: [(CGFloat(1), "desktop"), (0.5, "phone or tablet scaled into the panel")])
    func theCopyIsWhatsVisible(scale: CGFloat, label: String) async throws {
        let preview = PreviewController()
        let size = CGSize(width: 400, height: 600)
        let window = try await host(preview, size: size, scale: scale)
        defer { window.orderOut(nil) }
        try await scroll(preview, to: 500)

        let png = try #require(await preview.visiblePNG(scale: window.backingScaleFactor), "\(label): no copy")
        let copy = try image(png)
        let screen = window.backingScaleFactor
        #expect(copy.width == Int(size.width * screen), "\(label): the visible width at the display's scale, got \(copy.width)")
        #expect(copy.height == Int(size.height * screen), "\(label): the visible height at the display's scale, got \(copy.height)")
        // Scrolled to 500: the top shows band 2 (400–600), 150 pt down band 3,
        // and the bottom (1090) band 5.
        #expect(band(in: copy, atPoint: 2, pointHeight: size.height) == 2, "\(label): top")
        #expect(band(in: copy, atPoint: 150, pointHeight: size.height) == 3, "\(label): 150 pt down")
        #expect(band(in: copy, atPoint: 590, pointHeight: size.height) == 5, "\(label): bottom")
    }

    /// A pick after scrolling crops the element you clicked, sharp.
    @Test func aPickCropsThePickedElementAfterScrolling() async throws {
        let preview = PreviewController()
        let size = CGSize(width: 400, height: 600)
        let window = try await host(preview, size: size, scale: 1)
        defer { window.orderOut(nil) }
        try await scroll(preview, to: 500)
        // Pick band 3 (600–800), as a click in Pick mode would.
        _ = try await preview.page.callJavaScript("window.__muxSend(window.__muxDescribe(document.body.children[3])); return true;")
        for _ in 0..<60 where preview.pickedCrop == nil { try await Task.sleep(for: .milliseconds(50)) }
        let crop = try image(try #require(preview.pickedCrop, "no crop"))
        let screen = window.backingScaleFactor
        #expect(crop.width == Int(424 * screen), "the element plus its margin at the display's scale, got \(crop.width)")
        #expect(band(in: crop, atPoint: 112, pointHeight: 224) == 3, "the picked band")
        #expect(band(in: crop, atPoint: 4, pointHeight: 224) == 2, "the margin above shows the band above")
    }

    @Test func theCropRectIsInTheVisibleArea() {
        var element = PickedElement.fixture
        element.x = 16; element.y = 1200; element.width = 300; element.height = 50
        #expect(PreviewController.cropRect(element, scrollX: 0, scrollY: 1000) == CGRect(x: 4, y: 188, width: 324, height: 74))
        #expect(PreviewController.snapshotWidth(400, scale: 2) == 800)
        #expect(PreviewController.snapshotWidth(400, scale: 0) == 400, "never below one pixel per point")
    }
}
#endif
