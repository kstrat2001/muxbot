import Foundation
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#endif
@testable import MuxBot

/// Where a render test writes its PNGs: MUXBOT_SHOTS when set, for a look;
/// otherwise a fresh temp folder that's removed afterward, so runs don't
/// pile files up in the app's temp directory.
func withShotsDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    if let shots = ProcessInfo.processInfo.environment["MUXBOT_SHOTS"] { return try body(URL(fileURLWithPath: shots)) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muxbot-shots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

/// A view rendered to PNG, on either platform (render tests).
@MainActor
func renderPNG(_ view: some View, scale: CGFloat = 2) throws -> Data {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    #if os(macOS)
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    return try #require(bitmap.representation(using: .png, properties: [:]))
    #else
    return try #require(renderer.uiImage?.pngData())
    #endif
}

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
