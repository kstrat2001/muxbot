import Foundation

/// Layout facts read by script from a page at one width. Measured, never
/// judged by a model.
struct LayoutFacts: Sendable, Equatable, Codable {
    struct Wide: Sendable, Equatable, Codable {
        var selector: String
        var width: Int
        var right: Int
    }
    struct Media: Sendable, Equatable, Codable {
        var media: String
        var matches: Bool
        var selectors: [String]
        /// The stylesheet's path (`/inertia/css/app.css`) when known.
        var source: String?
    }
    struct Section: Sendable, Equatable, Codable {
        var selector: String
        var width: Int
        var left: Int
        var display: String
        /// Grid columns, when it's a grid.
        var columns: Int?
        var paddingLeft: String
        var paddingRight: String
        var fontSize: String
        var maxWidth: String
        /// Where its text starts and ends (the nearest text inside it):
        /// a full-width section with 0px padding is fine when an inner
        /// container keeps the text in.
        var textLeft: Int? = nil
        var textRight: Int? = nil
        /// `row` or `column` for a flex box.
        var flexDirection: String? = nil
        /// Its direct children's widths (the first four).
        var children: [Int]? = nil

        /// How its children are arranged, to compare across widths.
        var arrangement: String { "\(display)|\(flexDirection ?? "")|\(columns ?? 1)" }

        /// "a row (402px and 378px side by side)", "a column", "a 2-column grid".
        var arrangementText: String {
            if display.contains("flex") {
                if flexDirection?.hasPrefix("column") == true { return "a column" }
                let kids = children ?? []
                return kids.count >= 2 ? "a row (\(kids.prefix(3).map { "\($0)px" }.joined(separator: " and ")) side by side)" : "a row"
            }
            if display.contains("grid") {
                let c = columns ?? 1
                return c > 1 ? "a \(c)-column grid" : "one column"
            }
            return display
        }
    }

    var viewport: Int
    var scrollWidth: Int
    var clientWidth: Int
    var wide: [Wide]
    var media: [Media]
    var sections: [Section]
}

/// Measures a page at several widths (an offscreen web view in the app,
/// a mock in tests).
@MainActor
protocol LayoutProbing: AnyObject {
    func measure(url: URL, widths: [Int]) async -> [LayoutFacts]
}

/// Which issues get measured, at which widths, and what the numbers say.
enum LayoutMeasure {
    static let presets = [390, 768, 820, 1024]
    static let desktop = 1440

    /// A screenshot, or words about sizing, spacing or layout.
    static func isVisual(_ issue: GitHubIssue) -> Bool {
        let text = "\(issue.title)\n\(issue.body ?? "")".lowercased()
        if text.contains("<img") || text.contains("![") { return true }
        let words = ["sizing", "size", "padding", "margin", "spacing", "layout", "overflow", "looks off", "wrap",
                     "align", "cut off", "pushed", "too wide", "too narrow", "squished", "overlap", "gutter", "responsive"]
        return words.contains { text.contains($0) }
    }

    /// The issue's width when it's a device preset, with desktop to
    /// compare; otherwise every preset and desktop.
    static func widths(forViewport viewport: Int?) -> [Int] {
        if let viewport, let i = presets.firstIndex(of: viewport) {
            // The next preset down shows whether the layout switches between them.
            return [viewport] + (i > 0 ? [presets[i - 1]] : []) + [desktop]
        }
        return presets + [desktop]
    }

    /// For a bug draft: the reported width, the presets either side of it,
    /// and desktop.
    static func widths(around width: Int) -> [Int] {
        var out = [width]
        if let below = presets.filter({ $0 < width }).max() { out.append(below) }
        if let above = presets.filter({ $0 > width }).min() { out.append(above) }
        if width != desktop { out.append(desktop) }
        return out
    }

    struct Measured: Equatable {
        var lines: [String]
        var doneWhen: String?
        var likelyFile: String?
        /// Overflow, something wider than the screen, or no side padding.
        var foundProblem: Bool
        /// A section laid out differently at the next preset down, and why.
        var layoutSwitch: String? = nil
        /// The @media rule (and file) behind that switch.
        var switchRule: String? = nil
        /// The widths the change should cover ("769–1024px").
        var targetRange: String? = nil
        /// One sentence a brief leads with: the rule, what it switches, and
        /// the range to change.
        var switchLead: String? = nil
        /// "inertia/css/app.css, @media (max-width: 768px)" when a rule is
        /// behind the switch.
        var switchPlace: String? = nil
        /// The switch, for checking after the run: the section, the
        /// arrangement wanted, the preset below, and the top of the range.
        var switchSelector: String? = nil
        var switchWanted: String? = nil
        var switchBelow: Int? = nil
        var switchHigh: Int? = nil

        /// Where to look: the switching rule and its file, else the file.
        var likelyPlace: String? { switchPlace ?? likelyFile }
    }

    static func summarize(_ facts: [LayoutFacts], focus: Int?) -> Measured {
        var lines: [String] = []
        var done: String?
        var problem = false
        var files: [String] = []
        for f in facts {
            let at = "At \(f.viewport)px:"
            let over = f.scrollWidth - f.clientWidth
            let wide = f.wide.filter { $0.width > f.viewport || $0.right > f.viewport }
            let edges = f.sections.filter { touchesEdges($0, viewport: f.viewport) }
            if over > 0 {
                lines.append("\(at) the page is \(over)px wider than the screen (scrollWidth \(f.scrollWidth)).")
            }
            if !wide.isEmpty {
                let list = wide.prefix(3).map { w in
                    w.right > w.width ? "\(w.selector) (\(w.width)px, right edge at \(w.right)px)" : "\(w.selector) (\(w.width)px)"
                }
                lines.append("\(at) wider than the screen: \(list.joined(separator: ", ")).")
            }
            for s in f.sections where (s.columns ?? 1) > 1 || s.maxWidth != "none" {
                guard over > 0 || !wide.isEmpty || f.viewport == focus else { continue }
                var parts: [String] = []
                if let c = s.columns, c > 1 { parts.append("a \(c)-column grid") }
                if s.maxWidth != "none" { parts.append("max-width \(s.maxWidth)") }
                parts.append("font \(s.fontSize)")
                let what = parts.first?.hasPrefix("a ") == true ? "is " + parts.joined(separator: ", ") : "has " + parts.joined(separator: ", ")
                lines.append("\(at) \(s.selector) \(what).")
            }
            for s in edges {
                lines.append("\(at) \(s.selector)'s text touches the page edges (0px side padding).")
            }
            // Vite lists a stylesheet twice (by URL and by absolute path): one rule each.
            var seenRules = Set<String>()
            let media = f.media.filter { seenRules.insert("\($0.media)|\($0.selectors.joined(separator: ","))").inserted }
            let matching = media.filter(\.matches)
            if matching.isEmpty, !media.isEmpty, f.viewport != desktop {
                let rules = media.prefix(3).map { "\($0.media)\(file($0.source).map { " in \($0)" } ?? "")" }
                let only = media.count == 1 ? "the only one is" : "there are"
                lines.append("\(at) no @media rule matches; \(only) \(rules.joined(separator: ", ")).")
            } else if !matching.isEmpty {
                let rules = matching.prefix(3).map { "\($0.media)\(file($0.source).map { " in \($0)" } ?? "")" }
                lines.append("\(at) @media \(rules.joined(separator: ", ")) applies.")
            }
            files += media.compactMap { file($0.source) }
            let broken = over > 0 || !wide.isEmpty || !edges.isEmpty
            if broken {
                problem = true
                if done == nil || f.viewport == focus {
                    let others = facts.filter { $0.viewport != f.viewport && $0.scrollWidth <= $0.clientWidth && $0.wide.isEmpty }.map(\.viewport)
                    let keep = others.contains(desktop) ? ", and \(desktop)px looks the same as now" : ""
                    if over > 0 || !wide.isEmpty {
                        done = "at \(f.viewport)px nothing is wider than the screen\(keep)."
                    } else if let s = edges.first {
                        done = "at \(f.viewport)px \(s.selector) keeps side padding\(keep)."
                    }
                }
            } else if f.viewport == desktop || f.viewport != focus {
                lines.append("\(at) fits; nothing is wider than the screen.")
            }
        }
        // The same section arranged differently at the next preset down (a
        // row at 820px, a column at 768px), and the @media rule that switches it.
        var switchLine: String?
        var switchRule: String?
        var targetRange: String?
        var switchLead: String?
        var switchPlace: String?
        var switchSelector: String?, switchWanted: String?, switchBelow: Int?, switchHigh: Int?
        if let focus, let at = facts.first(where: { $0.viewport == focus }),
           let below = facts.filter({ $0.viewport < focus }).max(by: { $0.viewport < $1.viewport }) {
            for s in at.sections {
                guard let other = below.sections.first(where: { $0.selector == s.selector }), other.arrangement != s.arrangement else { continue }
                let rule = below.media.first { m in m.matches && !at.media.contains { $0.media == m.media && $0.matches } }
                let from = rule.map { r in ", from @media \(r.media)\(file(r.source).map { " in \($0)" } ?? "")" } ?? ""
                switchLine = "At \(focus)px \(s.selector) is \(s.arrangementText); at \(below.viewport)px it's \(other.arrangementText)\(from)."
                lines.insert(switchLine!, at: 0)
                if let f = rule.flatMap({ file($0.source) }) { files.insert(f, at: 0) }
                // The range to change: just above the smaller preset up to the
                // largest tablet preset ("769–1024px").
                let low = below.viewport + 1
                let high = presets.filter { $0 > below.viewport }.max() ?? focus
                targetRange = "\(low)–\(high)px"
                switchSelector = s.selector; switchBelow = below.viewport; switchHigh = high
                let wanted = Self.short(other.arrangementText), now = Self.short(s.arrangementText)
                switchWanted = wanted
                switchRule = rule.map { r in "@media \(r.media)\(file(r.source).map { " in \($0)" } ?? "")" }
                switchPlace = rule.flatMap { r in file(r.source).map { "\($0), @media \(r.media)" } }
                switchLead = (switchRule.map { "\($0) switches \(s.selector) to \(wanted) at \(below.viewport)px" }
                              ?? "\(s.selector) is \(wanted) at \(below.viewport)px")
                    + ", but it's \(now) at \(focus)px. Make it \(wanted) from \(low)px to \(high)px too."
                if done == nil {
                    let keep = facts.contains { $0.viewport == desktop } ? ", and \(desktop)px looks the same as now" : ""
                    done = "from \(low)px to \(high)px \(s.selector) is \(wanted), as at \(below.viewport)px\(keep)."
                }
                break
            }
        }
        // Deduplicate lines while keeping their order.
        var seen = Set<String>()
        lines = lines.filter { seen.insert($0).inserted }
        return Measured(lines: lines, doneWhen: done, likelyFile: files.first, foundProblem: problem, layoutSwitch: switchLine,
                        switchRule: switchRule, targetRange: targetRange, switchLead: switchLead, switchPlace: switchPlace,
                        switchSelector: switchSelector, switchWanted: switchWanted, switchBelow: switchBelow, switchHigh: switchHigh)
    }

    /// The block a brief carries.
    static func block(_ m: Measured) -> String {
        (["Measured in the preview:"] + m.lines.map { "- \($0)" }).joined(separator: "\n")
    }

    /// The measured lines in a brief, for the dispatch card.
    static func measuredLines(in brief: String) -> [String] {
        let lines = brief.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "Measured in the preview:") else { return [] }
        return Array(lines[(start + 1)...].prefix { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) })
    }

    /// "a row (402px and 378px side by side)" → "a row".
    static func short(_ arrangement: String) -> String {
        arrangement.replacingOccurrences(of: #" \(.*\)"#, with: "", options: .regularExpression)
    }

    /// "16px" → 16.
    /// A section whose text runs to the page's edge with 0px side padding
    /// (an inner container keeping the text in is fine).
    static func touchesEdges(_ s: LayoutFacts.Section, viewport: Int) -> Bool {
        guard px(s.paddingLeft) == 0 || px(s.paddingRight) == 0 else { return false }
        return (s.textLeft.map { $0 <= 1 } ?? false) || (s.textRight.map { $0 >= viewport - 1 } ?? false)
    }

    private static func px(_ value: String) -> Double { Double(value.replacingOccurrences(of: "px", with: "")) ?? -1 }

    /// "/inertia/css/app.css?t=1" → "inertia/css/app.css"; nil for inline styles.
    private static func file(_ source: String?) -> String? {
        guard var path = source, !path.isEmpty else { return nil }
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        while path.hasPrefix("/") { path.removeFirst() }
        return path.isEmpty ? nil : path
    }

    /// Layout facts as JSON (call with `width`): overflow, elements wider than the viewport,
    /// @media rules (and whether each matches), and the main sections' boxes.
    static let factsScript = """
        // The width it was laid out at (passed in): on iOS the web view zooms
        // out to fit wide content, so innerWidth would report the content.
        const vw = typeof width === 'number' ? width : document.documentElement.clientWidth;
        const de = document.documentElement;
        const sel = (el) => {
          if (el.id) return el.tagName.toLowerCase() + '#' + el.id;
          let s = el.tagName.toLowerCase();
          if (el.classList && el.classList.length) s += '.' + Array.from(el.classList).slice(0, 3).join('.');
          return s;
        };
        const wide = [];
        for (const el of document.querySelectorAll('body *')) {
          const r = el.getBoundingClientRect();
          if (r.width > vw + 1 || r.right > vw + 1) {
            const parent = el.parentElement && el.parentElement.getBoundingClientRect();
            if (parent && (parent.width > vw + 1 || parent.right > vw + 1)) continue;   // its parent says it
            wide.push({ selector: sel(el), width: Math.round(r.width), right: Math.round(r.right) });
          }
        }
        wide.sort((a, b) => b.right - a.right);
        const media = [];
        for (const sheet of Array.from(document.styleSheets)) {
          let rules;
          try { rules = sheet.cssRules; } catch (e) { continue; }
          const node = sheet.ownerNode;
          const source = sheet.href ? new URL(sheet.href).pathname : (node && node.dataset && node.dataset.viteDevId) || null;
          for (const r of Array.from(rules)) {
            if (r.type !== CSSRule.MEDIA_RULE) continue;
            const text = r.conditionText || r.media.mediaText;
            media.push({ media: text, matches: window.matchMedia(text).matches,
                         selectors: Array.from(r.cssRules).map(x => x.selectorText).filter(Boolean).slice(0, 6), source });
          }
        }
        const nodes = Array.from(document.querySelectorAll('header, main > *, section, footer'));
        const sections = Array.from(new Set(nodes)).slice(0, 12).map(el => {
          const r = el.getBoundingClientRect(), cs = getComputedStyle(el);
          const cols = cs.display.includes('grid') && cs.gridTemplateColumns !== 'none' ? cs.gridTemplateColumns.split(' ').length : null;
          // Where its text actually sits: the leftmost and rightmost text boxes inside it.
          let textLeft = null, textRight = null;
          const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
          for (let n = walker.nextNode(), seen = 0; n && seen < 400; n = walker.nextNode(), seen++) {
            if (!n.textContent.trim()) continue;
            const range = document.createRange(); range.selectNodeContents(n);
            const b = range.getBoundingClientRect();
            if (b.width === 0) continue;
            textLeft = textLeft === null ? b.left : Math.min(textLeft, b.left);
            textRight = textRight === null ? b.right : Math.max(textRight, b.right);
          }
          return { selector: sel(el), width: Math.round(r.width), left: Math.round(r.left), display: cs.display, columns: cols,
                   paddingLeft: cs.paddingLeft, paddingRight: cs.paddingRight, fontSize: cs.fontSize, maxWidth: cs.maxWidth,
                   textLeft: textLeft === null ? null : Math.round(textLeft), textRight: textRight === null ? null : Math.round(textRight),
                   flexDirection: cs.display.includes('flex') ? cs.flexDirection : null,
                   children: Array.from(el.children).slice(0, 4).map(c => Math.round(c.getBoundingClientRect().width)) };
        });
        return JSON.stringify({ viewport: vw, scrollWidth: de.scrollWidth, clientWidth: de.clientWidth,
                                wide: wide.slice(0, 8), media, sections });
        """
}
