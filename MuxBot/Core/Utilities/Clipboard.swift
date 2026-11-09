import Foundation
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
#endif

/// Every copy in the app goes through here. On macOS an image goes on the
/// pasteboard as TIFF (what Finder's Show Clipboard, Preview and most apps
/// read) and PNG, whatever format it came in; text as a plain string. The
/// old contents are cleared first.
enum Clipboard {
    /// Puts text on the clipboard.
    @MainActor
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        copy(text, to: .general)
        #endif
    }

    /// Puts an image on the clipboard. Returns false, leaving the clipboard
    /// as it was, when the data isn't an image.
    @MainActor @discardableResult
    static func copyImage(_ data: Data) -> Bool {
        #if os(iOS)
        guard let image = UIImage(data: data), let png = image.pngData() else { return false }
        UIPasteboard.general.setItems([[UTType.png.identifier: png]])
        return true
        #else
        return copyImage(data, to: .general)
        #endif
    }

    #if os(macOS)
    @MainActor
    static func copy(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    @MainActor @discardableResult
    static func copyImage(_ data: Data, to board: NSPasteboard) -> Bool {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        item.setData(png, forType: .png)
        board.clearContents()
        return board.writeObjects([item])
    }
    #endif
}
