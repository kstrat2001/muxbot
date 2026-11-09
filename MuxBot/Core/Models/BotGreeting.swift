import Foundation

/// A bot's first message, said to you. A bot's instructions or a
/// template's persona are addressed to the model ("You look after…"), so
/// they're never read out as the greeting.
enum BotGreeting {
    /// A new thread's hello. `about` is what you wrote about the bot; it's
    /// kept only when it reads as a description, not as a prompt.
    static func text(name: String, about: String, hasPreview: Bool) -> String {
        let hello = String(localized: "Hi, I'm \(name).")
        let next = hasPreview
            ? String(localized: "Tell me what to change, or point at something in the preview.")
            : String(localized: "Tell me what needs doing; nothing runs until you approve it.")
        guard let line = description(about) else { return "\(hello) \(next)" }
        return "\(hello) \(line) \(next)"
    }

    /// The hello in a project you just started.
    static func started(name: String, hasFirstRun: Bool) -> String {
        hasFirstRun
            ? String(localized: "Hi, I'm \(name). Here's a first change, made from what you told me. Tap Approve to see it in the preview, then tell me what to change or point at something on the page.")
            : String(localized: "Hi, I'm \(name). Tell me what to change, or point at something in the preview.")
    }

    /// One line you wrote about the bot, ending in a period; nil for a
    /// prompt (it talks to "you") or more than one line.
    static func description(_ about: String) -> String? {
        let text = about.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        let lower = text.lowercased()
        guard !lower.hasPrefix("you "), !lower.hasPrefix("you're "), !lower.hasPrefix("act as") else { return nil }
        return text.last.map { ".!?".contains($0) } == true ? text : text + "."
    }
}
