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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let splitView = enclosingSplitView() else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(splitViewDidResize),
                name: NSSplitView.didResizeSubviewsNotification, object: splitView
            )
            scheduleCheck()
        }

        @objc private func splitViewDidResize() {
            // Sidebar transitions resize continuously; correct once they settle.
            pendingCheck?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.enforce() }
            pendingCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        func scheduleCheck() {
            guard !isScheduled else { return }
            isScheduled = true
            // Let SwiftUI finish its own pass before moving dividers.
            DispatchQueue.main.async { [weak self] in
                self?.isScheduled = false
                self?.enforce()
            }
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
