import Foundation

/// Asking a bot for its preview in words ("start the preview", "where's the
/// preview?"): the app opens the panel, which starts it or says why it
/// can't. Rules only, never the model, so it never becomes crew work.
/// The words live in `AppAction`, the registry of what the app does itself.
enum PreviewRequest {
    /// Whether the message only asks to see the preview (`AppAction`'s
    /// open-preview entry).
    static func matches(_ text: String) -> Bool { AppAction.match(text) == .openPreview }

    static var openingText: String { String(localized: "Opening the preview.") }

    /// The bot has nothing this Mac can preview.
    static func cantText(_ name: String) -> String {
        #if os(macOS)
        String(localized: "\(name) has no project to preview yet. Add its folder or repo in its info, and the preview starts from there.")
        #else
        String(localized: "The preview runs on your Mac. Open \(name) in Mux Bot there to see it.")
        #endif
    }
}
