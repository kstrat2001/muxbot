#if os(macOS)
import AppKit
import SwiftUI

/// Sizes the split view pane this sits in, through the `NSSplitView` around
/// it (SwiftUI's `HSplitView` has no hook for its divider):
/// - when `key` changes (the preview opens, another bot, another device
///   size), the pane takes `paneWidth`;
/// - a double-click on the divider just before the pane fits it to the page
///   (`fitWidth`);
/// - a width you drag the divider to, or the double-click's, is reported
///   through `resized`, so it can be kept.
/// nil widths leave the pane as it is.
struct SplitDividerDoubleClick: NSViewRepresentable {
    var key: String = ""
    var paneWidth: CGFloat? = nil
    let fitWidth: CGFloat?
    var resized: (CGFloat) -> Void = { _ in }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.fitWidth = fitWidth
        view.resized = resized
        view.request(key: key, width: paneWidth)
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var fitWidth: CGFloat?
        var resized: (CGFloat) -> Void = { _ in }
        private var monitor: Any?
        private var observer: NSObjectProtocol?
        private weak var split: NSSplitView?
        /// The last key whose width was applied, and the one waiting.
        private var appliedKey: String?
        private var pending: (key: String, width: CGFloat)?
        /// Our own resize, so it isn't reported as yours.
        private var applying = false
        private var reportTask: Task<Void, Never>?

        /// Clicks pass through to the page.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
            split = enclosingSplitView
            if let split {
                observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                                                  object: split, queue: .main) { [weak self] note in
                    // Only a divider you dragged names its index.
                    let dragged = note.userInfo?["NSSplitViewDividerIndex"] != nil
                    MainActor.assumeIsolated { if dragged { self?.userResized() } }
                }
            }
            applyPendingSoon()
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            monitor = nil
            observer = nil
            reportTask?.cancel()
        }

        /// A width for `key`, applied once per key. A nil width (no real
        /// height yet, or Fit) waits for the next request.
        func request(key: String, width: CGFloat?) {
            guard key != appliedKey else { return }
            guard let width else { pending = nil; return }
            pending = (key, width)
            applyPendingSoon()
        }

        /// After SwiftUI's own layout pass, so the split view has its panes.
        private func applyPendingSoon() {
            guard pending != nil, window != nil else { return }
            Task { @MainActor [weak self] in self?.applyPending() }
        }

        private func applyPending() {
            guard let pending, let split, let (index, _) = pane(in: split) else { return }
            self.pending = nil
            appliedKey = pending.key
            setWidth(pending.width, index: index, in: split)
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.clickCount == 2, event.window === window, let fitWidth,
                  let split, split.isVertical, let (index, panes) = pane(in: split) else { return false }
            let before = panes[index - 1].frame, pane = panes[index].frame
            // The divider is thin: a couple of points either side still count.
            let divider = NSRect(x: before.maxX, y: 0, width: max(0, pane.minX - before.maxX), height: split.bounds.height)
                .insetBy(dx: -3, dy: 0)
            guard divider.contains(split.convert(event.locationInWindow, from: nil)) else { return false }
            setWidth(fitWidth, index: index, in: split)
            report(after: .zero)
            return true
        }

        private func setWidth(_ width: CGFloat, index: Int, in split: NSSplitView) {
            let pane = split.arrangedSubviews[index].frame
            let wanted = pane.maxX - width - split.dividerThickness
            let position = min(max(wanted, split.minPossiblePositionOfDivider(at: index - 1)),
                               split.maxPossiblePositionOfDivider(at: index - 1))
            applying = true
            split.setPosition(position, ofDividerAt: index - 1)
            applying = false
        }

        private func userResized() {
            guard !applying else { return }
            report(after: .milliseconds(300))
        }

        /// Once a drag settles, the pane's width is yours.
        private func report(after delay: Duration) {
            reportTask?.cancel()
            reportTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, let split, let (index, panes) = pane(in: split) else { return }
                resized(panes[index].frame.width)
            }
        }

        /// This pane's index among the split view's panes, when one comes
        /// before it (so there's a divider to move).
        private func pane(in split: NSSplitView) -> (Int, [NSView])? {
            let panes = split.arrangedSubviews
            guard let index = panes.firstIndex(where: { isDescendant(of: $0) }), index > 0 else { return nil }
            return (index, panes)
        }

        private var enclosingSplitView: NSSplitView? {
            var view = superview
            while let current = view {
                if let split = current as? NSSplitView { return split }
                view = current.superview
            }
            return nil
        }
    }
}
#endif
