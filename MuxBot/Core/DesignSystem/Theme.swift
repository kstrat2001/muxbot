import SwiftUI

// MARK: - Color Palette

extension Color {
    static let brandGreen = Color(red: 0.15, green: 0.72, blue: 0.55)
    /// Darker green for body-size text (passes 4.5:1 on white and card gray).
    static let brandGreenAccessible = Color(red: 0.01, green: 0.38, blue: 0.24)
    static let brandBlue = Color(red: 0.25, green: 0.52, blue: 0.96)
    static let brandRed = Color(red: 0.96, green: 0.32, blue: 0.35)
    static let brandOrange = Color(red: 0.96, green: 0.62, blue: 0.22)

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
