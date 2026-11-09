import SwiftUI

// MARK: - Color Palette

extension Color {
    static let brandGreen = Color(red: 0.15, green: 0.72, blue: 0.55)
    /// Darker green for body-size text (passes 4.5:1 on white and card gray).
    static let brandGreenAccessible = Color(red: 0.01, green: 0.38, blue: 0.24)
    static let brandBlue = Color(red: 0.25, green: 0.52, blue: 0.96)
    static let brandRed = Color(red: 0.96, green: 0.32, blue: 0.35)
    static let brandOrange = Color(red: 0.96, green: 0.62, blue: 0.22)

    /// Secondary text: the system's secondary label is about 3.4–4:1 in light
    /// mode, under the 4.5:1 text needs; this is at least 4.5:1 on the
    /// window and card backgrounds in both schemes (ContrastTests).
    static let secondaryTextLightHex = "5c5c62"
    static let secondaryTextDarkHex = "a1a1a8"
    #if os(iOS)
    static let secondaryText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: secondaryTextDarkHex) : UIColor(hex: secondaryTextLightHex) })
    #else
    static let secondaryText = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: secondaryTextDarkHex) : NSColor(hex: secondaryTextLightHex) })
    #endif

    /// Borders of fields and inputs: at least 3:1 against the window and card
    /// backgrounds in both schemes (ContrastTests).
    static let fieldBorderLightHex = "6e6e73"
    static let fieldBorderDarkHex = "8e8e93"
    #if os(iOS)
    static let fieldBorder = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: fieldBorderDarkHex) : UIColor(hex: fieldBorderLightHex) })
    #else
    static let fieldBorder = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: fieldBorderDarkHex) : NSColor(hex: fieldBorderLightHex) })
    #endif

    #if os(iOS)
    static let cardBackground = Color(uiColor: .secondarySystemBackground)
    static let elevatedBackground = Color(uiColor: .tertiarySystemBackground)
    #else
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let elevatedBackground = Color(nsColor: .underPageBackgroundColor)
    #endif
}

// MARK: - Typography (Dynamic Type text styles only; never .system(size:))

enum AppFont {
    static func largeTitle(_ weight: Font.Weight = .bold) -> Font { .system(.largeTitle, design: .rounded, weight: weight) }
    static func title2(_ weight: Font.Weight = .semibold) -> Font { .system(.title2, design: .rounded, weight: weight) }
    static func headline(_ weight: Font.Weight = .semibold) -> Font { .system(.headline, weight: weight) }
    static func body(_ weight: Font.Weight = .regular) -> Font { .system(.body, weight: weight) }
    static func subheadline(_ weight: Font.Weight = .regular) -> Font { .system(.subheadline, weight: weight) }
    static func footnote(_ weight: Font.Weight = .regular) -> Font { .system(.footnote, weight: weight) }
    static func caption(_ weight: Font.Weight = .regular) -> Font { .system(.caption, weight: weight) }
}

// MARK: - Spacing

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Corner Radius

enum CornerRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let pill: CGFloat = 100
}

#if os(iOS)
extension UIColor {
    convenience init(hex: String) {
        let v = UInt64(hex, radix: 16) ?? 0
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
#else
extension NSColor {
    convenience init(hex: String) {
        let v = UInt64(hex, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
#endif
