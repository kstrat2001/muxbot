#if os(macOS)
import AppKit
import SwiftUI

/// Double-click on the split view divider just before the pane this sits in
/// sizes that pane to `paneWidth` (as far as the panes' limits allow). nil
/// leaves the double-click to the split view. SwiftUI's `HSplitView` has no
/// hook for its divider, so this finds the `NSSplitView` around it.
struct SplitDividerDoubleClick: NSViewRepresentable {
    let paneWidth: CGFloat?

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.paneWidth = paneWidth }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        var paneWidth: CGFloat?
        private var monitor: Any?

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
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.clickCount == 2, event.window === window, let paneWidth,
                  let split = enclosingSplitView, split.isVertical else { return false }
            let panes = split.arrangedSubviews
            guard let index = panes.firstIndex(where: { isDescendant(of: $0) }), index > 0 else { return false }
            let before = panes[index - 1].frame, pane = panes[index].frame
            // The divider is thin: a couple of points either side still count.
            let divider = NSRect(x: before.maxX, y: 0, width: max(0, pane.minX - before.maxX), height: split.bounds.height)
                .insetBy(dx: -3, dy: 0)
            guard divider.contains(split.convert(event.locationInWindow, from: nil)) else { return false }
            let wanted = pane.maxX - paneWidth - split.dividerThickness
            let position = min(max(wanted, split.minPossiblePositionOfDivider(at: index - 1)),
                               split.maxPossiblePositionOfDivider(at: index - 1))
            split.setPosition(position, ofDividerAt: index - 1)
            return true
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
