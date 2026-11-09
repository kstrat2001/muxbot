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
