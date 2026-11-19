import AppKit
import SwiftUI

/// Column widths for the main window. `navigationSplitViewColumnWidth` is not
/// applied on a first launch without saved split positions, which left the
/// sidebar and list squeezed to their intrinsic widths, and hiding the sidebar
/// let the list grow past its maximum. This guard keeps visible leading columns
/// within range once layout or a sidebar transition settles.
enum SplitColumnLayout {
    struct Column: Equatable {
        var min: CGFloat
        var ideal: CGFloat
        var max: CGFloat
    }

    static let sidebar = Column(min: 220, ideal: 248, max: 300)
    static let list = Column(min: 360, ideal: 420, max: 520)
    static let detailMinimum: CGFloat = 440

    /// Returns the widths to apply to the visible leading columns, or nil when
    /// every column is already within its range. The trailing detail column
    /// keeps at least `detailMinimum`; leading columns give way first.
    static func correctedWidths(
        widths: [CGFloat],
        columns: [Column],
        availableWidth: CGFloat
    ) -> [CGFloat]? {
        guard !widths.isEmpty, widths.count == columns.count else { return nil }
        let outOfRange = zip(widths, columns).contains { width, column in
            width < column.min - 0.5 || width > column.max + 0.5
        }
        guard outOfRange else { return nil }
        var remaining = availableWidth - detailMinimum
        return zip(widths, columns).map { width, column in
            let target = width < column.min - 0.5 ? column.ideal : Swift.min(width, column.max)
            let applied = Swift.max(column.min, Swift.min(target, remaining))
            remaining -= applied
            return applied
        }
    }
}

/// Attach to a view inside the split view's trailing column.
struct SplitColumnGuard: NSViewRepresentable {
    var columns: [SplitColumnLayout.Column]

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.columns = columns
        return view
    }

    func updateNSView(_ nsView: GuardView, context: Context) {
        nsView.columns = columns
        nsView.scheduleCheck()
    }

    final class GuardView: NSView {
        var columns: [SplitColumnLayout.Column] = []
        private var isScheduled = false
        private var pendingCheck: DispatchWorkItem?
        private var mouseMonitor: Any?
        private var sidebarLock: (item: NSSplitViewItem, minimum: CGFloat, maximum: CGFloat)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            mouseMonitor = nil
            unlockSidebar()
            guard let splitView = enclosingSplitView() else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                self?.handleMouse(event)
                return event
            }
            QuietSplitDivider.apply(to: splitView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(splitViewDidResize),
                name: NSSplitView.didResizeSubviewsNotification, object: splitView
            )
            scheduleCheck()
        }

        @objc private func splitViewDidResize() {
            if let splitView = enclosingSplitView() { QuietSplitDivider.apply(to: splitView) }
            // Sidebar transitions resize continuously; correct once they settle.
            pendingCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.enforce() }
            pendingCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            if let splitView = enclosingSplitView() { QuietSplitDivider.apply(to: splitView) }
        }

        func scheduleCheck() {
            guard !isScheduled else { return }
            isScheduled = true
            // Let SwiftUI finish its own pass before moving dividers.
            DispatchQueue.main.async { [weak self] in
                self?.isScheduled = false
                if let splitView = self?.enclosingSplitView() { QuietSplitDivider.apply(to: splitView) }
                self?.enforce()
            }
        }

        /// Dragging the list/reading divider past the list's minimum or
        /// maximum made AppKit push the sidebar's divider too. While that
        /// divider is held, the sidebar is pinned to its current width.
        private func handleMouse(_ event: NSEvent) {
            guard event.type == .leftMouseDown else {
                unlockSidebar()
                return
            }
            guard let splitView = enclosingSplitView(), event.window === splitView.window else { return }
            let arranged = splitView.arrangedSubviews
            guard arranged.count >= 3, !splitView.isSubviewCollapsed(arranged[0]),
                  !arranged[0].isHidden, arranged[0].frame.width >= 1 else { return }
            let point = splitView.convert(event.locationInWindow, from: nil)
            let dividerX = arranged[1].frame.maxX + splitView.dividerThickness / 2
            guard splitView.bounds.contains(point), abs(point.x - dividerX) <= 6 else { return }
            lockSidebar(in: splitView)
        }

        func lockSidebar(in splitView: NSSplitView) {
            guard sidebarLock == nil,
                  let controller = splitView.delegate as? NSSplitViewController,
                  let item = controller.splitViewItems.first,
                  let sidebar = splitView.arrangedSubviews.first else { return }
            sidebarLock = (item, item.minimumThickness, item.maximumThickness)
            let width = sidebar.frame.width
            item.minimumThickness = width
            item.maximumThickness = width
        }

        func unlockSidebar() {
            guard let lock = sidebarLock else { return }
            sidebarLock = nil
            lock.item.minimumThickness = lock.minimum
            lock.item.maximumThickness = lock.maximum
        }

        private func enclosingSplitView() -> NSSplitView? {
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView, split.isVertical,
                   split.arrangedSubviews.count >= 2 {
                    return split
                }
                ancestor = view.superview
            }
            return nil
        }

        private func enforce() {
            guard let splitView = enclosingSplitView(), splitView.bounds.width > 0,
                  splitView.window?.inLiveResize != true else { return }
            let arranged = splitView.arrangedSubviews
            // The last arranged view is the detail column and takes the rest.
            let leadingCount = arranged.count - 1
            guard leadingCount >= columns.count else { return }
            let firstIndex = leadingCount - columns.count
            let visible = columns.indices.compactMap { offset -> (index: Int, column: SplitColumnLayout.Column)? in
                let index = firstIndex + offset
                let view = arranged[index]
                guard !splitView.isSubviewCollapsed(view), !view.isHidden, view.frame.width >= 1 else { return nil }
                return (index, columns[offset])
            }
            guard let first = visible.first else { return }
            let origin = arranged[first.index].frame.minX
            let dividers = CGFloat(visible.count) * splitView.dividerThickness
            guard let widths = SplitColumnLayout.correctedWidths(
                widths: visible.map { arranged[$0.index].frame.width },
                columns: visible.map(\.column),
                availableWidth: splitView.bounds.width - origin - dividers
            ) else { return }
            var x = origin
            for (entry, width) in zip(visible, widths) {
                x += width
                splitView.setPosition(x, ofDividerAt: entry.index)
                x += splitView.dividerThickness
            }
        }
    }
}

/// Fog separates panels by tone, not by lines. AppKit draws split dividers
/// as their own subviews; they are made transparent (still draggable) and the
/// split view's own background shows the list tone through the 1pt gap, next
/// to the reading pane's soft edge shadow.
enum QuietSplitDivider {
    @MainActor
    static func apply(to splitView: NSSplitView) {
        for divider in splitView.subviews where NSStringFromClass(type(of: divider)).contains("Divider") {
            if divider.alphaValue != 0 { divider.alphaValue = 0 }
        }
        splitView.wantsLayer = true
        splitView.effectiveAppearance.performAsCurrentDrawingAppearance {
            splitView.layer?.backgroundColor = MarkXInterface.listBackgroundNS.cgColor
        }
    }
}
