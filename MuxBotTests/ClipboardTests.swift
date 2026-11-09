import Foundation
import Testing
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import MuxBot

#if os(macOS)

/// Copy puts real, readable types on the macOS pasteboard: an image as TIFF
/// (what Finder's Show Clipboard, Preview and most apps read) and PNG,
/// whatever format it came in; text as a string. Tests use a private
/// pasteboard, never the user's clipboard.
@Suite(.serialized) @MainActor
struct ClipboardTests {
    let board = NSPasteboard(name: NSPasteboard.Name("com.darklyenergized.muxbot.tests"))

    static func image(_ type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(.systemRed, atX: 1, y: 1)
        return rep.representation(using: type, properties: [:])!
    }

    @Test func anImageIsReadableAsTIFFAndPNG() {
        board.clearContents()
        #expect(Clipboard.copyImage(Self.image(.png), to: board))
        #expect(board.data(forType: .tiff) != nil, "Finder and most apps read TIFF")
        #expect(board.data(forType: .png) != nil)
        #expect(NSImage(pasteboard: board) != nil)
    }

    @Test func anImageInAnotherFormatStillLandsAsAnImage() {
        board.clearContents()
        #expect(Clipboard.copyImage(Self.image(.jpeg), to: board))
        #expect(board.data(forType: .tiff) != nil && board.data(forType: .png) != nil)
    }

    @Test func dataThatIsntAnImageIsRefusedAndLeavesTheClipboardAlone() {
        board.clearContents()
        Clipboard.copy("before", to: board)
        #expect(!Clipboard.copyImage(Data("not an image".utf8), to: board))
        #expect(board.string(forType: .string) == "before")
    }

    @Test func textReadsBack() {
        Clipboard.copy("darkmux client approve", to: board)
        #expect(board.string(forType: .string) == "darkmux client approve")
        #expect(board.data(forType: .tiff) == nil, "the old contents are cleared")
    }
}
#endif

/// What the preview's screenshot export actually hands back, so the copy
/// path decodes it rather than labeling it PNG blindly.
@Suite(.serialized) @MainActor
struct PreviewExportFormatTests {
    @Test func theExportIsAnImageTheClipboardTakes() async throws {
        let page = WebPage()
        page.load(html: "<html><body style='background:#c00'><h1>Hi</h1></body></html>", baseURL: URL(string: "about:blank")!)
        for _ in 0..<100 where page.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        let data = try await page.exported(as: .image())
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4e, 0x47]), "WebPage exports PNG")
        #if os(macOS)
        let board = NSPasteboard(name: NSPasteboard.Name("com.darklyenergized.muxbot.tests"))
        #expect(Clipboard.copyImage(data, to: board))
        #expect(board.data(forType: .tiff) != nil && board.data(forType: .png) != nil)
        #else
        // iOS copies only to the general pasteboard, which tests never touch:
        // check the decode the copy path relies on.
        #expect(UIImage(data: data)?.pngData() != nil)
        #endif
    }

    /// The visible-region capture, exactly as the preview's camera does it.
    @Test func theVisibleRegionCapture() async throws {
        let page = WebPage()
        page.load(html: "<html><body style='background:#c00;height:3000px'><h1>Hi</h1></body></html>", baseURL: URL(string: "about:blank")!)
        for _ in 0..<100 where page.isLoading { try await Task.sleep(for: .milliseconds(50)) }
        let json = try await page.callJavaScript("return JSON.stringify([scrollX, scrollY, innerWidth, innerHeight])") as? String
        let v = try #require(json.flatMap { try? JSONDecoder().decode([Double].self, from: Data($0.utf8)) })
        let data = try await page.exported(as: .image(region: .rect(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))))
        #if os(macOS)
        let board = NSPasteboard(name: NSPasteboard.Name("com.darklyenergized.muxbot.tests"))
        #expect(Clipboard.copyImage(data, to: board))
        #expect(NSImage(pasteboard: board) != nil)
        #else
        #expect(UIImage(data: data) != nil)
        #endif
    }
}
