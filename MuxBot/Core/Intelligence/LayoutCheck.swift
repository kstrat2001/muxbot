import Foundation

/// The done-when, checked: after a run that changed files, the app measures
/// the preview again at the widths the brief named and says whether the
/// fix holds, and what failed when it doesn't. Measured, never judged.
enum LayoutCheck {
    struct Spec: Equatable, Sendable {
        var page: URL
        /// The section whose layout should change (nil: only overflow).
        var selector: String?
        /// Its arrangement wanted across the range ("a column").
        var wanted: String?
        /// Widths where it should now be `wanted`.
        var rangeWidths: [Int] = []
        /// Widths that should look as they did before: the arrangement then.
        var unchanged: [Int: String] = [:]
        /// Widths where nothing may be wider than the screen.
        var overflowWidths: [Int] = []

        var widths: [Int] {
            var out = rangeWidths + unchanged.keys.sorted()
            for w in overflowWidths where !out.contains(w) { out.append(w) }
            return out
        }
    }

    struct Result: Equatable, Sendable {
        var met: Bool
        var failures: [String]
    }

    /// What to check after the run, from the measurement the brief was
    /// built on; nil when that measurement found nothing to fix.
    static func spec(from m: LayoutMeasure.Measured, before: [LayoutFacts], focus: Int, page: URL) -> Spec? {
        if let sel = m.switchSelector, let wanted = m.switchWanted, let below = m.switchBelow, let high = m.switchHigh {
            let range = Set(LayoutMeasure.presets.filter { $0 > below && $0 <= high } + [focus]).sorted()
            var unchanged: [Int: String] = [:]
            for f in before where f.viewport == below || f.viewport == LayoutMeasure.desktop {
                if let s = f.sections.first(where: { $0.selector == sel }) { unchanged[f.viewport] = s.arrangementText }
            }
            return Spec(page: page, selector: sel, wanted: wanted, rangeWidths: range, unchanged: unchanged, overflowWidths: range)
        }
        guard m.foundProblem else { return nil }
        return Spec(page: page, overflowWidths: [focus])
    }

    static func evaluate(_ spec: Spec, after: [LayoutFacts]) -> Result {
        var failures: [String] = []
        func facts(_ w: Int) -> LayoutFacts? { after.first { $0.viewport == w } }
        func section(_ f: LayoutFacts) -> LayoutFacts.Section? { spec.selector.flatMap { sel in f.sections.first { $0.selector == sel } } }
        if let sel = spec.selector, let wanted = spec.wanted {
            for w in spec.rangeWidths {
                guard let f = facts(w) else { failures.append("At \(w)px the page didn't load."); continue }
                guard let s = section(f) else { failures.append("At \(w)px \(sel) wasn't found."); continue }
                let now = LayoutMeasure.short(s.arrangementText)
                if now != wanted { failures.append("At \(w)px \(sel) is \(now), not \(LayoutMeasure.short(wanted)).") }
            }
            for (w, was) in spec.unchanged.sorted(by: { $0.key < $1.key }) {
                guard let f = facts(w), let s = section(f) else { continue }
                let then = LayoutMeasure.short(was), now = LayoutMeasure.short(s.arrangementText)
                if now != then { failures.append("At \(w)px \(sel) changed from \(then) to \(now).") }
            }
        }
        for w in spec.overflowWidths {
            guard let f = facts(w) else { if spec.selector == nil { failures.append("At \(w)px the page didn't load.") }; continue }
            let over = f.scrollWidth - f.clientWidth
            if over > 0 {
                failures.append("At \(w)px the page is \(over)px wider than the screen.")
            } else if let first = f.wide.first(where: { $0.width > f.viewport || $0.right > f.viewport }) {
                failures.append("At \(w)px \(first.selector) is wider than the screen.")
            }
        }
        return Result(met: failures.isEmpty, failures: failures)
    }

    /// Your reply for "Run again with these numbers".
    static func rerunChange(_ result: Result) -> String {
        "Not done yet. Measured in the preview after your change: \(result.failures.joined(separator: " ")) Fix that, keeping everything else as it is now."
    }
}
