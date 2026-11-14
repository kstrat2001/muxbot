import Foundation

/// Asking a bot for its preview in words ("start the preview", "where's the
/// preview?"): the app opens the panel, which starts it or says why it
/// can't. Rules only, never the model, so it never becomes crew work.
enum PreviewRequest {
    /// Words a request for the preview may hold, and nothing else: "show
    /// the price on the preview" names something to change, so it's work.
    private static let allowed: Set<String> = [
        "start", "open", "show", "run", "launch", "see", "view", "display", "turn", "on", "bring", "up",
        "restart", "reload", "refresh", "load", "get", "go", "toggle",
        "where", "is", "s", "whats", "what", "happened", "to",
        "the", "a", "my", "me", "our", "this", "that", "it", "its", "again", "now", "please", "pls",
        "can", "could", "would", "will", "you", "i", "want", "let", "lets", "us", "need",
        "live", "site", "website", "page", "app", "button",
    ]

    static func matches(_ text: String) -> Bool {
        let words = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter }
            .map(String.init)
        guard words.contains(where: { $0 == "preview" || $0 == "previews" }), words.count <= 8 else { return false }
        return words.allSatisfy { $0 == "preview" || $0 == "previews" || allowed.contains($0) }
    }

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
