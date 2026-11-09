import Foundation
import SwiftUI
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import MuxBot

/// Contrast of the design system's colors against the backgrounds they sit
/// on, in light and dark: 3:1 for things that aren't text (an avatar's
/// headset, field borders), 4.5:1 for text (WCAG 2.2, 1.4.3 and 1.4.11).
/// The math is on plain sRGB values; only resolving a system color in an
/// appearance is per platform.
struct ContrastTests {
    struct RGB: Equatable {
        var r, g, b: Double
        var a = 1.0

        init(r: Double, g: Double, b: Double, a: Double = 1) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }

        init(hex: String) {
            let v = UInt64(hex, radix: 16) ?? 0
            self.init(r: Double((v >> 16) & 0xff) / 255, g: Double((v >> 8) & 0xff) / 255, b: Double(v & 0xff) / 255)
        }

        /// sRGB relative luminance.
        var luminance: Double {
            func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }

        /// Composited onto a backdrop when it's translucent.
        func over(_ backdrop: RGB) -> RGB {
            guard a < 1 else { return self }
            return RGB(r: r * a + backdrop.r * (1 - a), g: g * a + backdrop.g * (1 - a), b: b * a + backdrop.b * (1 - a))
        }
    }

    enum Scheme: String { case light, dark }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (a.luminance, b.luminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    #if os(macOS)
    static func rgb(_ c: NSColor) -> RGB {
        let s = c.usingColorSpace(.sRGB)!
        return RGB(r: s.redComponent, g: s.greenComponent, b: s.blueComponent, a: s.alphaComponent)
    }

    /// A system color as drawn in an appearance.
    static func resolved(_ color: NSColor, _ scheme: Scheme) -> RGB {
        var out = RGB(r: 0, g: 0, b: 0)
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { out = rgb(color) }
        return out
    }

    static func systemBackgrounds(_ scheme: Scheme) -> [(String, RGB)] {
        [("macOS window", resolved(.windowBackgroundColor, scheme)), ("macOS card", resolved(.controlBackgroundColor, scheme))]
    }

    static let secondaryLabel = NSColor.secondaryLabelColor
    static let label = NSColor.labelColor
    /// Where command boxes sit (`Color.elevatedBackground`).
    static let elevated = NSColor.underPageBackgroundColor
    static func rgb(_ color: Color) -> RGB { rgb(NSColor(color)) }
    #else
    static func rgb(_ c: UIColor) -> RGB {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGB(r: r, g: g, b: b, a: a)
    }

    /// A system color as drawn in an appearance.
    static func resolved(_ color: UIColor, _ scheme: Scheme) -> RGB {
        rgb(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)))
    }

    static func systemBackgrounds(_ scheme: Scheme) -> [(String, RGB)] {
        [("iOS system background", resolved(.systemBackground, scheme)),
         ("iOS system card", resolved(.secondarySystemBackground, scheme))]
    }

    static let secondaryLabel = UIColor.secondaryLabel
    static let label = UIColor.label
    /// Where command boxes sit (`Color.elevatedBackground`).
    static let elevated = UIColor.tertiarySystemBackground
    static func rgb(_ color: Color) -> RGB { rgb(UIColor(color)) }
    #endif

    /// Where avatars and fields sit: this platform's window and card
    /// backgrounds, plus iOS's as their fixed values (so the Mac run covers
    /// the phone too).
    static func backgrounds(_ scheme: Scheme) -> [(String, RGB)] {
        let dark = scheme == .dark
        return systemBackgrounds(scheme) + [
            ("iOS background", RGB(hex: dark ? "000000" : "ffffff")),
            ("iOS card", RGB(hex: dark ? "1c1c1e" : "f2f2f7")),
            ("iOS elevated", RGB(hex: dark ? "2c2c2e" : "ffffff")),
        ]
    }

    @Test func theHeadsetStandsOutInDarkMode() {
        for (name, bg) in Self.backgrounds(.dark) {
            let r = Self.ratio(RGB(hex: AvatarPainter.headsetDarkHex), bg)
            #expect(r >= 3, "dark headset on \(name): \(r)")
        }
        for (name, bg) in Self.backgrounds(.light) {
            #expect(Self.ratio(RGB(hex: AvatarPainter.headsetHex), bg) >= 3, "headset on \(name)")
        }
    }

    @Test func fieldBordersMeetThreeToOne() {
        for (scheme, hex) in [(Scheme.light, Color.fieldBorderLightHex), (.dark, Color.fieldBorderDarkHex)] {
            for (name, bg) in Self.backgrounds(scheme) {
                let r = Self.ratio(RGB(hex: hex), bg)
                #expect(r >= 3, "\(scheme.rawValue) field border on \(name): \(r)")
            }
        }
    }

    @Test func secondaryTextMeetsFourAndAHalf() {
        for (scheme, hex) in [(Scheme.light, Color.secondaryTextLightHex), (.dark, Color.secondaryTextDarkHex)] {
            for (name, bg) in Self.backgrounds(scheme) {
                let r = Self.ratio(RGB(hex: hex), bg)
                #expect(r >= 4.5, "\(scheme.rawValue) secondary text on \(name): \(r)")
            }
        }
    }

    /// Why the app has its own secondary text color: the system's is under
    /// 4.5:1 on white in light mode.
    @Test func theSystemSecondaryLabelFallsShortInLight() {
        let white = RGB(hex: "ffffff")
        #expect(Self.ratio(Self.resolved(Self.secondaryLabel, .light).over(white), white) < 4.5)
    }

    /// Command boxes sit on the elevated surface; their text is primary.
    @Test func commandTextOnTheElevatedSurface() {
        for scheme in [Scheme.light, .dark] {
            let bg = Self.resolved(Self.elevated, scheme)
            let text = Self.resolved(Self.label, scheme).over(bg)
            #expect(Self.ratio(text, bg) >= 4.5, "\(scheme.rawValue)")
        }
    }

    @Test func greenTextUsesTheAccessibleGreenInLight() {
        let green = Self.rgb(Color.brandGreenAccessible)
        #expect(Self.ratio(green, RGB(hex: "ffffff")) >= 4.5)
        #expect(Self.ratio(green, RGB(hex: "f2f2f7")) >= 4.5)
    }

    /// The hex math matches the platform's own sRGB color.
    @Test func hexMatchesThePlatformColor() {
        let ours = RGB(hex: "5c5c62"), theirs = Self.resolved(.init(hex: "5c5c62"), .light)
        #expect(abs(ours.r - theirs.r) < 0.002 && abs(ours.g - theirs.g) < 0.002 && abs(ours.b - theirs.b) < 0.002, "\(theirs)")
    }
}
