import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum Clipboard {
    /// Puts a PNG on the clipboard as an image. Returns false if it isn't one.
    @MainActor @discardableResult
    static func copyPNG(_ png: Data) -> Bool {
        #if os(iOS)
        guard let image = UIImage(data: png) else { return false }
        UIPasteboard.general.image = image
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        #endif
        return true
    }
}
