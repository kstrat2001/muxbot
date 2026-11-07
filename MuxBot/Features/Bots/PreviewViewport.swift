import CoreGraphics

/// The width the preview renders the page at. Device widths render at
/// their real CSS width (so the site's own breakpoints apply) and scale
/// down to fit the panel; Fit uses the panel as it is.
enum PreviewViewport: String, CaseIterable, Sendable {
    case fit, phone, tablet, desktop

    var width: CGFloat? {
        switch self {
        case .fit: nil
        case .phone: 390
        case .tablet: 820
        case .desktop: 1440
        }
    }

    var systemImage: String {
        switch self {
        case .fit: "arrow.left.and.right.square"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .desktop: "desktopcomputer"
        }
    }

    var label: String {
        switch self {
        case .fit: "Fit to panel"
        case .phone: "Phone, 390 wide"
        case .tablet: "Tablet, 820 wide"
        case .desktop: "Desktop, 1440 wide"
        }
    }

    struct Layout: Equatable { var width: CGFloat; var height: CGFloat; var scale: CGFloat }

    /// Page size and scale for a panel of `size`: the page lays out at the
    /// device width, scaled down (never up) to fit, and tall enough to fill
    /// the panel after scaling.
    func layout(in size: CGSize) -> Layout {
        guard let width else { return Layout(width: size.width, height: size.height, scale: 1) }
        let scale = min(1, size.width / width)
        return Layout(width: width, height: size.height / scale, scale: scale)
    }

    /// The first viewport a preview recipe lists, else Fit.
    static func preferred(from recipe: [String]?) -> PreviewViewport {
        recipe?.lazy.compactMap { PreviewViewport(rawValue: $0) }.first ?? .fit
    }
}
