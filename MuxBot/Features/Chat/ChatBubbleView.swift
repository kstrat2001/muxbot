import SwiftUI

struct ChatBubbleView: View {
    let role: ChatRole
    let content: String

    private var isUser: Bool { role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: Spacing.xxl) }
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
            if !isUser { Spacer(minLength: Spacing.xxl) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUser ? "You" : "Reply"): \(content)")
    }
}
