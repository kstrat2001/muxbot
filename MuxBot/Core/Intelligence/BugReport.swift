import Foundation

/// Measurements of one element in the preview, read with JavaScript.
struct ElementFact: Sendable, Equatable, Codable {
    var term: String
    var tag: String
    var left: Int
    var right: Int
    var width: Int
    var paddingLeft: String
    var paddingRight: String
    var marginLeft: String
    var marginRight: String
}

/// What the preview page shows, as text a small model (and an issue) can use.
struct PageFacts: Sendable, Equatable, Codable {
    var viewport: Int
    var url: String
    var matches: [ElementFact]
}

/// Something that can read facts from the live preview. The preview
/// panel's web page in the app; a mock in tests.
@MainActor
protocol PageInspecting: AnyObject {
    func facts(for terms: [String]) async -> PageFacts?
    func snapshotPNG() async -> Data?
}

/// A bug report drafted from what the user described, plus page facts.
struct BugDraft: Sendable, Equatable, Codable {
    var title: String
    var described: String
    var page: String
    var viewport: Int?
    var facts: [String]
    var repo: String?

    var body: String {
        var lines = [
            "**What's wrong**", described, "",
            "**Steps**", "1. Open \(page)\(viewport.map { " at \($0)px wide" } ?? "")", "2. Look at the element described above", "",
            "**Expected**", "It looks right (see description).", "",
            "**Actual**", described,
        ]
        if !facts.isEmpty { lines += ["", "**Page facts (measured in the Mux Bot preview)**"] + facts.map { "- \($0)" } }
        lines += ["", "_Drafted by Mux Bot. Paste the preview screenshot here._"]
        return lines.joined(separator: "\n")
    }

    /// github.com/<repo>/issues/new prefilled with title and body.
    var issueURL: URL? {
        guard let repo else { return nil }
        var parts = URLComponents(string: "https://github.com/\(repo)/issues/new")
        parts?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        return parts?.url
    }
}

enum BugReport {
    private static let filler: Set<String> = [
        "border", "padding", "margin", "looks", "like", "left", "right", "there", "about", "button",
        "should", "would", "could", "spacing", "broken", "overlap", "overlaps", "page", "text", "color", "font",
    ]

    /// Words worth searching the page for: identifiers like Start_a_Project
    /// or quoted text first, else longer words that aren't layout talk.
    static func searchTerms(in text: String) -> [String] {
        let quoted = text.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }.map(String.init)
        let identifiers = words.filter { $0.contains("_") || ($0.first?.isUppercase == true && $0.count > 3) }
        if !quoted.isEmpty { return Array(quoted.prefix(3)) }
        if !identifiers.isEmpty { return Array(NSOrderedSet(array: identifiers).array.compactMap { $0 as? String }.prefix(3)) }
        return words.filter { $0.count >= 5 && !filler.contains($0.lowercased()) }.prefix(3).map { $0 }
    }

    /// One line per measured element: "The Start_a_Project box (fieldset)
    /// is 0px from the left edge and 0px from the right at 905px wide;
    /// padding 0px / 0px, margin 0px / 0px."
    static func describe(_ facts: PageFacts) -> [String] {
        facts.matches.map { m in
            "The \(m.term) box (\(m.tag)) is \(m.left)px from the left edge and \(m.right)px from the right at \(facts.viewport)px wide; padding \(m.paddingLeft) / \(m.paddingRight), margin \(m.marginLeft) / \(m.marginRight)."
        }
    }

    static func draft(from text: String, facts: PageFacts?, page: URL?, repo: String?) -> BugDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSentence = trimmed.split(whereSeparator: { ".!\n".contains($0) }).first.map(String.init) ?? trimmed
        let title = String(firstSentence.prefix(80)).capitalizedFirst
        let path = facts?.url ?? page?.path() ?? "/"
        return BugDraft(title: title, described: trimmed, page: path, viewport: facts?.viewport,
                        facts: facts.map(describe) ?? [], repo: repo)
    }

    /// The JavaScript run in the preview: finds the element matching each
    /// term, climbs to its bordered box, and measures it.
    static let factsScript = """
        const vw = window.innerWidth;
        const all = Array.from(document.querySelectorAll('body *'));
        const out = [];
        for (const t of terms) {
          const tl = t.toLowerCase();
          const el = all.filter(e => e.children.length === 0 && (e.textContent || '').toLowerCase().includes(tl))
                        .sort((a, b) => a.textContent.length - b.textContent.length)[0];
          if (!el) continue;
          let box = el;
          for (let n = el; n && n !== document.body; n = n.parentElement) {
            const s = getComputedStyle(n);
            if (parseFloat(s.borderLeftWidth) > 0 || parseFloat(s.borderTopWidth) > 0) { box = n; break; }
          }
          const r = box.getBoundingClientRect(), s = getComputedStyle(box);
          out.push({ term: t, tag: box.tagName.toLowerCase(), left: Math.round(r.left), right: Math.round(vw - r.right),
                     width: Math.round(r.width), paddingLeft: s.paddingLeft, paddingRight: s.paddingRight,
                     marginLeft: s.marginLeft, marginRight: s.marginRight });
        }
        return JSON.stringify({ viewport: vw, url: location.pathname, matches: out });
        """
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
