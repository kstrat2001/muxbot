import SwiftUI

extension View {
    /// Messages-style width: at most 70% of the thread and 520pt, hugging
    /// its content, pinned to the bot's side (leading) or yours (trailing).
    func chatColumn(alignment: Alignment) -> some View {
        containerRelativeFrame(.horizontal, alignment: alignment) { width, _ in min(width * 0.7, 520) }
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

struct ChatBubbleView: View {
    let role: ChatRole
    let content: String

    private var isUser: Bool { role == .user }

    var body: some View {
        if role == .system {
            Text(content)
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xs)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        Text(content)
                .font(AppFont.body())
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.lg)
                        .fill(isUser ? Color.brandGreenAccessible : Color.cardBackground)
                )
                .textSelection(.enabled)
                .chatColumn(alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUser ? "You" : "Reply"): \(content)")
    }
}
