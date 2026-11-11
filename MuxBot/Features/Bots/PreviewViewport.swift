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
        // SwiftUI's first pass can be .zero: never a size under 1pt to
        // divide by (a NaN or infinite height otherwise).
        let size = CGSize(width: max(1, size.width), height: max(1, size.height))
        guard let width else { return Layout(width: size.width, height: size.height, scale: 1) }
        if let height {
            let room = CGSize(width: max(1, size.width - 2 * Self.devicePadding), height: max(1, size.height - 2 * Self.devicePadding))
            let scale = min(1, room.width / width, room.height / height)
            return Layout(width: width, height: height, scale: scale, framed: true)
        }
        let scale = min(1, size.width / width)
        return Layout(width: width, height: size.height / scale, scale: scale)
    }

    /// How wide the panel should be to show the whole page with no empty
    /// sides, for a panel `panelHeight` tall (double-click on the divider).
    /// A device fills it at the largest scale its height allows (never above
    /// 1), with its frame's padding; Desktop is its own width; Fit is the
    /// panel already, so nil.
    func fittedPanelWidth(panelHeight: CGFloat) -> CGFloat? {
        guard let width else { return nil }
        guard let height else { return width }
        let room = max(1, panelHeight - 2 * Self.devicePadding)
        return (width * min(1, room / height)).rounded(.up) + 2 * Self.devicePadding
    }

    /// The pane's width when the preview opens: the width you last set,
    /// else the page's fit (nil for Fit: the pane stays as it is). nil too
    /// before the panel has a real height to fit to.
    func openingPaneWidth(stored: Double?, panelHeight: CGFloat) -> CGFloat? {
        if let stored, stored > 0 { return CGFloat(stored) }
        guard panelHeight >= 100 else { return nil }
        return fittedPanelWidth(panelHeight: panelHeight)
    }

    /// What the panel draws for a panel of `size`. A device or Fit is
    /// always the panel's current fit: a device's page keeps its own CSS
    /// width, so a resize only changes the scale and never re-lays out the
    /// page. Desktop keeps its settled page height while a resize settles
    /// (no re-layout on every frame), but scales down at once when the
    /// panel gets narrower, so the page never runs past the panel's edge.
    func shown(settled: Layout?, in size: CGSize) -> Layout {
        let live = layout(in: size)
        guard width != nil, height == nil, var kept = settled, kept.width == live.width else { return live }
        kept.scale = min(kept.scale, live.scale)
        return kept
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
