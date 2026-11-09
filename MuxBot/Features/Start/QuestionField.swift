import SwiftUI

/// One start-a-project question: the whole question as a label above (never
/// truncated), a left-aligned field under it that grows for longer answers,
/// and the question's examples as suggestions you tap, wrapping onto more
/// lines rather than scrolling out of sight. Used on macOS and iOS alike.
struct QuestionField: View {
    let question: PlaybookQuestion
    @Binding var text: String
    /// Lines the field grows to: one for a name, more for a sentence.
    var lines: ClosedRange<Int> = 1...4

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(question.label)
                .font(AppFont.body(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                // A name is one line (Return never adds a line break to it).
                if lines.upperBound <= 1 {
                    TextField(question.label, text: $text)
                } else {
                    TextField(question.label, text: $text, axis: .vertical).lineLimit(lines)
                }
            }
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !question.suggestions.isEmpty {
                WrappingStack(spacing: Spacing.sm) {
                    ForEach(question.suggestions, id: \.self) { suggestion in
                        Button(suggestion) { text = PlaybookQuestion.adding(suggestion, to: text) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint("Adds “\(suggestion)” to your answer")
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

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
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    /// Which views go on which line, for a width.
    static func rows(_ subviews: Subviews, width: CGFloat, spacing: CGFloat) -> [Row] {
        rows(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: width, spacing: spacing)
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
