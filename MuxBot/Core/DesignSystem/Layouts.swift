import SwiftUI

/// Lays its views out left to right, starting a new line when one is full.
struct WrappingStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = Self.rows(subviews, width: proposal.width ?? .infinity, spacing: spacing)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in Self.rows(subviews, width: bounds.width, spacing: spacing) {
            var x = bounds.minX
            for index in row.indices {
                let size = Self.size(of: subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    /// Which views go on which line, for a width.
    static func rows(_ subviews: Subviews, width: CGFloat, spacing: CGFloat) -> [Row] {
        rows(sizes: subviews.map { size(of: $0, width: width) }, width: width, spacing: spacing)
    }

    static func rows(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, size) in sizes.enumerated() {
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Equal rows: as many columns as fit that divide the item count evenly
/// (12 colors as 12, 6, 4, 3 or 2 per row), so a row never ends with one
/// item on its own. Items are the same size.
struct EvenGrid: Layout {
    var spacing: CGFloat = 8

    /// The most columns that fit `width` and divide `count` evenly.
    static func columns(count: Int, itemWidth: CGFloat, width: CGFloat, spacing: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let fit = max(1, Int(((width + spacing) / (itemWidth + spacing)).rounded(.down)))
        return (1...min(fit, count)).last { count % $0 == 0 } ?? 1
    }

    private func layout(_ subviews: Subviews, width: CGFloat) -> (columns: Int, item: CGSize) {
        let item = subviews.reduce(CGSize.zero) { size, view in
            let s = view.sizeThatFits(.unspecified)
            return CGSize(width: max(size.width, s.width), height: max(size.height, s.height))
        }
        return (Self.columns(count: subviews.count, itemWidth: item.width, width: width, spacing: spacing), item)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (columns, item) = layout(subviews, width: proposal.width ?? .infinity)
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: CGFloat(columns) * item.width + CGFloat(columns - 1) * spacing,
                      height: CGFloat(rows) * item.height + CGFloat(max(rows - 1, 0)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, item) = layout(subviews, width: bounds.width)
        for (index, view) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index % columns) * (item.width + spacing)
            let y = bounds.minY + CGFloat(index / columns) * (item.height + spacing)
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item))
        }
    }
}

extension WrappingStack {
    /// A view wider than the row is measured at the row's width (so a
    /// long chip wraps its text instead of running past the edge).
    static func fitted(_ natural: CGSize, width: CGFloat, measure: (CGFloat) -> CGSize) -> CGSize {
        guard width.isFinite, natural.width > width else { return natural }
        return measure(width)
    }

    static func size(of subview: LayoutSubview, width: CGFloat) -> CGSize {
        fitted(subview.sizeThatFits(.unspecified), width: width) { subview.sizeThatFits(ProposedViewSize(width: $0, height: nil)) }
    }
}

/// A status label whose icon carries the color and whose words stay the
/// primary text color (green or orange text is too faint in light mode).
struct TintedIconLabelStyle: LabelStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        Label { configuration.title } icon: { configuration.icon.foregroundStyle(tint) }
    }
}

extension LabelStyle where Self == TintedIconLabelStyle {
    static func tintedIcon(_ tint: Color) -> TintedIconLabelStyle { TintedIconLabelStyle(tint: tint) }
}
