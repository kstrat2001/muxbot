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
        if let viewport, presets.contains(viewport) { return [viewport, desktop] }
        return presets + [desktop]
    }

    struct Measured: Equatable {
        var lines: [String]
        var doneWhen: String?
        var likelyFile: String?
        /// Overflow, something wider than the screen, or no side padding.
        var foundProblem: Bool
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
            let edges = f.sections.filter { $0.left <= 0 && px($0.paddingLeft) == 0 && px($0.paddingRight) == 0 && $0.width >= f.viewport - 1 }
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
                lines.append("\(at) \(s.selector) touches the page edges (0px side padding).")
            }
            let matching = f.media.filter(\.matches)
            if matching.isEmpty, !f.media.isEmpty, f.viewport != desktop {
                let rules = f.media.prefix(3).map { "\($0.media)\(file($0.source).map { " in \($0)" } ?? "")" }
                let only = f.media.count == 1 ? "the only one is" : "there are"
                lines.append("\(at) no @media rule matches; \(only) \(rules.joined(separator: ", ")).")
            } else if !matching.isEmpty {
                let rules = matching.prefix(3).map { "\($0.media)\(file($0.source).map { " in \($0)" } ?? "")" }
                lines.append("\(at) @media \(rules.joined(separator: ", ")) applies.")
            }
            files += f.media.compactMap { file($0.source) }
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
        // Deduplicate lines while keeping their order.
        var seen = Set<String>()
        lines = lines.filter { seen.insert($0).inserted }
        return Measured(lines: lines, doneWhen: done, likelyFile: files.first, foundProblem: problem)
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

    /// "16px" → 16.
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
          return { selector: sel(el), width: Math.round(r.width), left: Math.round(r.left), display: cs.display, columns: cols,
                   paddingLeft: cs.paddingLeft, paddingRight: cs.paddingRight, fontSize: cs.fontSize, maxWidth: cs.maxWidth };
        });
        return JSON.stringify({ viewport: vw, scrollWidth: de.scrollWidth, clientWidth: de.clientWidth,
                                wide: wide.slice(0, 8), media, sections });
        """
}
