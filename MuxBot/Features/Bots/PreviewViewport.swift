import CoreGraphics

/// The width the preview renders the page at. Device widths render at
/// their real CSS width (so the site's own breakpoints apply) and scale
/// down to fit the panel; Fit uses the panel as it is.
enum PreviewViewport: String, CaseIterable, Sendable {
    case fit, phone, smallTablet, tablet, desktop

    var width: CGFloat? {
        switch self {
        case .fit: nil
        case .phone: 390
        case .smallTablet: 768
        case .tablet: 820
        case .desktop: 1440
        }
    }

    var systemImage: String {
        switch self {
        case .fit: "arrow.left.and.right.square"
        case .phone: "iphone"
        case .smallTablet: "ipad"
        case .tablet: "ipad"
        case .desktop: "desktopcomputer"
        }
    }

    var label: String {
        switch self {
        case .fit: "Fit to panel"
        case .phone: "Phone, 390 wide"
        case .smallTablet: "Small tablet, 768 wide"
        case .tablet: "Tablet, 820 wide"
        case .desktop: "Desktop, 1440 wide"
        }
    }

    /// A device's screen height in points; nil for Fit and Desktop, which
    /// fill the panel.
    var height: CGFloat? {
        switch self {
        case .phone: 844
        case .smallTablet: 1024
        case .tablet: 1180
        case .fit, .desktop: nil
        }
    }

    /// Room around a device frame, in points.
    static let devicePadding: CGFloat = 16

    struct Layout: Equatable {
        var width: CGFloat
        var height: CGFloat
        var scale: CGFloat
        /// Drawn as a device: centered, in a rounded frame.
        var framed = false

        /// Where the scaled page sits in a panel of `size`: devices centered
        /// across, a little below the top; everything else at the corner.
        func origin(in size: CGSize) -> CGPoint {
            guard framed else { return .zero }
            return CGPoint(x: (size.width - width * scale) / 2, y: PreviewViewport.devicePadding)
        }
    }

    /// Page size and scale for a panel of `size`. A device lays out at its
    /// own width and height, scaled down (never up) to fit the panel both
    /// ways. Desktop lays out at its width, scaled down to fit across, and
    /// tall enough to fill the panel; Fit is the panel.
    func layout(in size: CGSize) -> Layout {
        guard let width else { return Layout(width: size.width, height: size.height, scale: 1) }
        if let height {
            let room = CGSize(width: max(1, size.width - 2 * Self.devicePadding), height: max(1, size.height - 2 * Self.devicePadding))
            let scale = min(1, room.width / width, room.height / height)
            return Layout(width: width, height: height, scale: scale, framed: true)
        }
        let scale = min(1, size.width / width)
        return Layout(width: width, height: size.height / scale, scale: scale)
    }

    /// The size this bot was last shown at on this Mac, else the first one
    /// its preview recipe lists, else Fit.
    static func resolve(stored: String?, recipe: [String]?) -> PreviewViewport {
        stored.flatMap(PreviewViewport.init(rawValue:)) ?? preferred(from: recipe)
    }

    /// The first viewport a preview recipe lists, else Fit.
    static func preferred(from recipe: [String]?) -> PreviewViewport {
        recipe?.lazy.compactMap { PreviewViewport(rawValue: $0) }.first ?? .fit
    }
}
