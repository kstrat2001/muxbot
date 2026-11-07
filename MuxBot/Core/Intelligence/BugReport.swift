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

/// An element you picked in the preview with the Pick button. Your next
/// message is about it.
struct PickedElement: Sendable, Equatable, Codable {
    var label: String
    var selector: String
    var tag: String
    var url: String
    var viewport: Int
    var left: Int
    var right: Int
    var width: Int
    var height: Int
    var paddingLeft: String
    var paddingRight: String
    var marginLeft: String
    var marginRight: String
    /// Position in the document, for cropping a snapshot.
    var x: Int
    var y: Int
    /// From the selection menu: "ask" or "bug".
    var intent: String? = nil
    /// From the selection menu: the text you selected.
    var selectedText: String? = nil

    /// "Start_a_Project · /pricing · 683px"
    var chip: String { "\(label) · \(url) · \(viewport)px" }

    var asFacts: PageFacts {
        PageFacts(viewport: viewport, url: url, matches: [
            ElementFact(term: label, tag: tag, left: left, right: right, width: width,
                        paddingLeft: paddingLeft, paddingRight: paddingRight,
                        marginLeft: marginLeft, marginRight: marginRight)])
    }
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
    /// CSS selector of the picked element, when you pointed at it.
    var selector: String? = nil
    /// One line on what should happen instead (the on-device model writes
    /// it from your words when it can).
    var expected: String? = nil

    var body: String {
        var lines = [
            "**What's wrong**", described, "",
            "**Steps**", "1. Open \(page)\(viewport.map { " at \($0)px wide" } ?? "")",
            selector.map { "2. Look at `\($0)`" } ?? "2. Look at the element described above", "",
            "**Expected**", expected ?? "_Describe what you expected._",
        ]
        if !facts.isEmpty { lines += ["", "**Page facts (measured in the Mux Bot preview)**"] + facts.map { "- \($0)" } }
        lines += ["", "**Screenshot:** paste below.", "", "_Drafted by Mux Bot._"]
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

    /// Installed on every poll (idempotent, so it survives reloads):
    /// `__muxDescribe` measures an element, and selecting text shows a small
    /// menu, "Ask about this" / "Report a bug here". A pick or a menu choice
    /// lands in `__muxPicked`, which this script returns and clears.
    static let ensureScript = """
        if (!window.__muxDescribe) {
          const selector = el => {
            const parts = [];
            for (let n = el; n && n !== document.body && parts.length < 5; n = n.parentElement) {
              let p = n.tagName.toLowerCase();
              if (n.id) { parts.unshift(p + '#' + n.id); break; }
              const cls = [...n.classList].slice(0, 2);
              if (cls.length) p += '.' + cls.join('.');
              const same = [...(n.parentElement ? n.parentElement.children : [])].filter(s => s.tagName === n.tagName);
              if (same.length > 1) p += ':nth-of-type(' + (same.indexOf(n) + 1) + ')';
              parts.unshift(p);
            }
            return parts.join(' > ');
          };
          window.__muxDescribe = (el, extra) => {
            const r = el.getBoundingClientRect(), s = getComputedStyle(el), vw = window.innerWidth;
            const text = ((el.innerText || '').trim().split('\\n')[0].slice(0, 40)) || el.tagName.toLowerCase();
            return JSON.stringify(Object.assign({ label: text, selector: selector(el), tag: el.tagName.toLowerCase(),
              url: location.pathname, viewport: vw, left: Math.round(r.left), right: Math.round(vw - r.right),
              width: Math.round(r.width), height: Math.round(r.height), paddingLeft: s.paddingLeft, paddingRight: s.paddingRight,
              marginLeft: s.marginLeft, marginRight: s.marginRight, x: Math.round(r.left + scrollX), y: Math.round(r.top + scrollY) }, extra || {}));
          };
          const menu = document.createElement('div');
          menu.style.cssText = 'position:fixed;z-index:2147483647;display:none;padding:5px;border-radius:10px;background:#1c2622;box-shadow:0 4px 16px rgba(0,0,0,.45);font:13px -apple-system,system-ui,sans-serif';
          const choose = intent => {
            const sel = getSelection();
            if (!sel || !sel.rangeCount) return;
            let el = sel.getRangeAt(0).commonAncestorContainer;
            if (el.nodeType !== 1) el = el.parentElement;
            // Selected text usually names a box: measure its bordered container.
            for (let n = el, i = 0; n && n !== document.body && i < 5; n = n.parentElement, i++) {
              const st = getComputedStyle(n);
              if (parseFloat(st.borderLeftWidth) > 0 || parseFloat(st.borderTopWidth) > 0) { el = n; break; }
            }
            const quote = sel.toString().trim().slice(0, 200);
            window.__muxPicked = window.__muxDescribe(el, { intent: intent, selectedText: quote });
            menu.style.display = 'none';
            sel.removeAllRanges();
          };
          for (const [title, intent] of [['Ask about this', 'ask'], ['Report a bug here', 'bug']]) {
            const b = document.createElement('button');
            b.textContent = title;
            b.style.cssText = 'background:#22d3a6;color:#032;border:0;border-radius:6px;padding:5px 9px;margin:0 3px;font:inherit;cursor:pointer';
            b.addEventListener('mousedown', e => { e.preventDefault(); e.stopPropagation(); choose(intent); });
            b.addEventListener('touchstart', e => { e.preventDefault(); e.stopPropagation(); choose(intent); }, { passive: false });
            menu.append(b);
          }
          document.body.appendChild(menu);
          document.addEventListener('selectionchange', () => {
            const sel = getSelection();
            if (!sel || sel.isCollapsed || !sel.toString().trim()) { menu.style.display = 'none'; return; }
            const r = sel.getRangeAt(0).getBoundingClientRect();
            menu.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 260)) + 'px';
            menu.style.top = Math.min(r.bottom + 8, window.innerHeight - 44) + 'px';
            menu.style.display = 'block';
          });
        }
        const picked = window.__muxPicked; window.__muxPicked = null; return picked;
        """

    /// Pick mode: hover highlights, a click (or tap) picks the element.
    static let pickerScript = """
        if (window.__muxPick) return true;
        const box = document.createElement('div');
        box.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483646;border:2px solid #22d3a6;background:rgba(34,211,166,.15);border-radius:3px;display:none';
        document.body.appendChild(box);
        const move = e => {
          const r = e.target.getBoundingClientRect();
          Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
        };
        const cleanup = () => {
          document.removeEventListener('mousemove', move, true);
          document.removeEventListener('click', pick, true);
          box.remove(); window.__muxPick = null;
        };
        const pick = e => { e.preventDefault(); e.stopPropagation(); window.__muxPicked = window.__muxDescribe(e.target); cleanup(); };
        document.addEventListener('mousemove', move, true);
        document.addEventListener('click', pick, true);
        window.__muxPick = { cleanup };
        return true;
        """

    static let cancelPickScript = "if (window.__muxPick) window.__muxPick.cleanup(); return true;"

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
