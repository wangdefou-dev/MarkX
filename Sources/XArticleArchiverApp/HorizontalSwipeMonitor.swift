import AppKit
import SwiftUI

/// Calls `onSwipeBack` once per gesture when two fingers swipe right over
/// this view (trackpad or Magic Mouse), like Back in Safari. Scroll events
/// are only observed, never consumed, so lists keep scrolling normally.
struct HorizontalSwipeMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onSwipeBack: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.isEnabled = isEnabled
        view.onSwipeBack = onSwipeBack
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onSwipeBack = onSwipeBack
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stop()
    }

    final class MonitorView: NSView {
        var isEnabled = false
        var onSwipeBack: () -> Void = {}
        private var monitor: Any?
        private var horizontal: CGFloat = 0
        private var vertical: CGFloat = 0
        private var hasFired = false

        /// Finger travel, in points, before the swipe counts.
        private static let threshold: CGFloat = 60

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                horizontal = 0
                vertical = 0
                hasFired = false
            }
            // Only live finger movement counts, not momentum or wheel clicks.
            guard isEnabled, !hasFired, event.phase.contains(.changed),
                  let window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            // With natural scrolling the deltas follow the fingers; without
            // it they are reversed. Either way, fingers moving right = back.
            let fingersX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            horizontal += fingersX
            vertical += abs(event.scrollingDeltaY)
            if horizontal > Self.threshold, horizontal > vertical * 2 {
                hasFired = true
                onSwipeBack()
            }
        }
    }
}
