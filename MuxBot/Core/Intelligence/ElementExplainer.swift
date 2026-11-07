import Foundation

/// Answers "what's this?" about an element picked in the preview, from its
/// measured facts, never by guessing from the chip's text.
enum ElementExplainer {
    static func isWhatsThis(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?!.")))
            .replacingOccurrences(of: "’", with: "'")
        let phrases = ["what's this", "whats this", "what is this", "what's that", "whats that", "what is that",
                       "what is it", "what's it", "explain this", "explain", "what am i looking at"]
        return phrases.contains(t)
    }

    /// What the element is on the page, in plain words.
    static func role(of element: PickedElement) -> String {
        switch element.tag {
        case "h1": "the page's main heading"
        case "h2", "h3", "h4": "a section heading"
        case "p": "a paragraph"
        case "a": "a link"
        case "button": "a button"
        case "img", "svg": "an image"
        case "nav": "the navigation"
        case "header": "the page header"
        case "footer": "the page footer"
        case "li": "a list item"
        case "input", "textarea", "select": "a form field"
        default: "a box on the page"
        }
    }

    static func explain(_ e: PickedElement) -> String {
        let text = e.label.trimmingCharacters(in: .whitespaces)
        var parts = ["That's \(role(of: e)) on \(e.url)" + (text.isEmpty || text == e.tag ? "." : ", showing “\(text.prefix(60))”.")]
        if let file = IssueBrief.likelyFile(forPage: e.url) {
            parts.append("It's most likely in \(file).")
        }
        var look: [String] = []
        if let size = e.fontSize { look.append("\(size)\(e.fontWeight.flatMap { Int($0) }.map { $0 >= 600 ? " bold" : "" } ?? "")") }
        if let family = e.fontFamily, !family.isEmpty { look.append(family.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))) }
        if let color = e.color { look.append("color \(color)") }
        let lookText = look.isEmpty ? "" : " in \(look.joined(separator: ", "))"
        parts.append("At \(e.viewport)px wide it's \(e.width)×\(e.height)\(lookText), \(e.left)px from the left edge and \(e.right)px from the right.")
        parts.append("Want me to change it, or report a problem with it?")
        return parts.joined(separator: " ")
    }
}
