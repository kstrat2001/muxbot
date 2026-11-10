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
                // The question is right above: the field doesn't repeat it as
                // its placeholder (it's still the field's spoken label).
                if lines.upperBound <= 1 {
                    TextField(question.label, text: $text, prompt: Text(""))
                } else {
                    TextField(question.label, text: $text, prompt: Text(""), axis: .vertical).lineLimit(lines)
                        #if os(iOS)
                        // An answer goes into the middle of a sentence ("The
                        // book is about a lighthouse…"): no capital first letter.
                        .textInputAutocapitalization(.never)
                        #endif
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
                            .tint(Color.accentText)
                            .accessibilityHint("Adds “\(suggestion)” to your answer")
                    }
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}
