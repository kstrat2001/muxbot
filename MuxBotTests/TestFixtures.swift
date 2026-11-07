import Foundation
@testable import MuxBot

/// Bots the routing tests use (formerly the app's personal starter bots).
enum Fixtures {
    static let defaults: [(name: String, systemImage: String, instructions: String, resources: [(ResourceKind, String)])] = [
        ("humancodereader", "eyeglasses",
         "The humancodereader.com website: a humorous AI code-review site. Site changes, previews and reviews.",
         [(.repo, "https://github.com/kstrat2001/hcr")]),
        ("darkmux", "square.stack.3d.up",
         "darkmux, the local-LLM orchestration CLI: features, fixes, evals and releases.",
         [(.repo, "https://github.com/kstrat2001/darkmux")]),
        ("Personal brand", "megaphone",
         "Posts, threads and articles in your voice, for X and Substack.",
         []),
        ("Daily update", "calendar",
         "A short daily briefing: what ran, what finished, what needs you, what's next.",
         []),
    ]
}
