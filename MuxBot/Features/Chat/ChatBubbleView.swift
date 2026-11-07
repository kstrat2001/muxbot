import SwiftUI

extension View {
    /// Messages-style width: at most 520pt, hugging its content, with a gap
    /// on the far side, pinned to the bot's side (leading) or yours
    /// (trailing). Fixed limits, not a fraction of the window, so resizing
    /// doesn't re-measure every bubble each frame (that flickered).
    func chatColumn(alignment: Alignment) -> some View {
        frame(maxWidth: 520, alignment: alignment)
            .padding(alignment == .trailing ? .leading : .trailing, 48)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

struct ChatBubbleView: View {
    let role: ChatRole
    let content: String
    /// The bot's GitHub repo ("owner/name"), so "#8" can link to it.
    var repo: String? = nil

    private var isUser: Bool { role == .user }

    var body: some View {
        if role == .system {
            Text(Linkify.attributed(content, repo: repo))
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.xs)
        } else {
            bubble
        }
    }

    /// Links read as links on the green bubble too: white and underlined.
    private var linked: AttributedString {
        var text = Linkify.attributed(content, repo: repo)
        guard isUser else { return text }
        for run in text.runs where run.link != nil { text[run.range].underlineStyle = .single }
        return text
    }

    private var bubble: some View {
        Text(linked)
                .tint(isUser ? Color.white : Color.accentColor)
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
