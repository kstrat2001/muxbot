import Foundation
import AppKit
import SwiftUI
import Testing
@testable import MuxBot

/// Contrast of the design system's colors against the backgrounds they sit
/// on, in light and dark: 3:1 for things that aren't text (an avatar's
/// headset, field borders), 4.5:1 for text (WCAG 2.2, 1.4.3 and 1.4.11).
struct ContrastTests {
    /// sRGB relative luminance.
    static func luminance(_ c: NSColor) -> Double {
        let s = c.usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(s.redComponent) + 0.7152 * lin(s.greenComponent) + 0.0722 * lin(s.blueComponent)
    }

    static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// A system color as drawn in an appearance, composited onto a backdrop
    /// when it's translucent.
    static func resolved(_ color: NSColor, _ appearance: NSAppearance.Name, over backdrop: NSColor? = nil) -> NSColor {
        var out = color
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB)!
        }
        guard let backdrop, out.alphaComponent < 1 else { return out }
        let a = out.alphaComponent, b = backdrop.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: out.redComponent * a + b.redComponent * (1 - a),
                       green: out.greenComponent * a + b.greenComponent * (1 - a),
                       blue: out.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
    }

    /// Where avatars and fields sit: the window and card backgrounds of both
    /// platforms (iOS's as their fixed system values).
    static func backgrounds(_ appearance: NSAppearance.Name) -> [(String, NSColor)] {
        let dark = appearance == .darkAqua
        return [
            ("macOS window", resolved(.windowBackgroundColor, appearance)),
            ("macOS card", resolved(.controlBackgroundColor, appearance)),
            ("iOS background", NSColor(hex: dark ? "000000" : "ffffff")),
            ("iOS card", NSColor(hex: dark ? "1c1c1e" : "f2f2f7")),
            ("iOS elevated", NSColor(hex: dark ? "2c2c2e" : "ffffff")),
        ]
    }

    @Test func theHeadsetStandsOutInDarkMode() {
        for (name, bg) in Self.backgrounds(.darkAqua) {
            let r = Self.ratio(NSColor(hex: AvatarPainter.headsetDarkHex), bg)
            #expect(r >= 3, "dark headset on \(name): \(r)")
        }
        for (name, bg) in Self.backgrounds(.aqua) {
            #expect(Self.ratio(NSColor(hex: AvatarPainter.headsetHex), bg) >= 3, "headset on \(name)")
        }
    }

    @Test func fieldBordersMeetThreeToOne() {
        for (scheme, hex) in [(NSAppearance.Name.aqua, Color.fieldBorderLightHex), (.darkAqua, Color.fieldBorderDarkHex)] {
            for (name, bg) in Self.backgrounds(scheme) {
                let r = Self.ratio(NSColor(hex: hex), bg)
                #expect(r >= 3, "\(scheme.rawValue) field border on \(name): \(r)")
            }
        }
    }

    @Test func secondaryTextMeetsFourAndAHalf() {
        for (scheme, hex) in [(NSAppearance.Name.aqua, Color.secondaryTextLightHex), (.darkAqua, Color.secondaryTextDarkHex)] {
            for (name, bg) in Self.backgrounds(scheme) {
                let r = Self.ratio(NSColor(hex: hex), bg)
                #expect(r >= 4.5, "\(scheme.rawValue) secondary text on \(name): \(r)")
            }
        }
    }

    /// Why the app has its own secondary text color: the system's is under
    /// 4.5:1 on white in light mode.
    @Test func theSystemSecondaryLabelFallsShortInLight() {
        let white = NSColor(hex: "ffffff")
        #expect(Self.ratio(Self.resolved(.secondaryLabelColor, .aqua, over: white), white) < 4.5)
    }

    /// Command boxes sit on the under-page surface; their text is primary.
    @Test func commandTextOnTheUnderPageSurface() {
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let bg = Self.resolved(.underPageBackgroundColor, scheme)
            let text = Self.resolved(.labelColor, scheme, over: bg)
            #expect(Self.ratio(text, bg) >= 4.5, "\(scheme.rawValue)")
        }
    }

    @Test func greenTextUsesTheAccessibleGreenInLight() {
        let green = NSColor(Color.brandGreenAccessible)
        #expect(Self.ratio(green, NSColor(hex: "ffffff")) >= 4.5)
        #expect(Self.ratio(green, NSColor(hex: "f2f2f7")) >= 4.5)
    }
}
