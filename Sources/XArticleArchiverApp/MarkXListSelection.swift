import AppKit
import SwiftUI

/// Fog-style list rows: a quiet rounded rectangle behind the hovered row and a
/// stronger one behind the selected row, instead of the system highlight. The
/// accent-blue highlight of a focused list made grey secondary text unreadable,
/// and the sidebar's own highlight was too faint to see; one drawn background
/// keeps text colours intact and looks the same with or without focus.
extension View {
    func markxSelectableRow(isSelected: Bool, horizontalInset: CGFloat = MarkXSpace.m) -> some View {
        modifier(MarkXSelectableRowModifier(isSelected: isSelected, horizontalInset: horizontalInset))
    }
}

private struct MarkXSelectableRowModifier: ViewModifier {
    let isSelected: Bool
    let horizontalInset: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .listRowBackground(
                RoundedRectangle(cornerRadius: MarkXRadius.card)
                    .fill(isSelected ? MarkXInterface.selection
                          : isHovered ? MarkXInterface.hover : Color.clear)
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 1)
            )
            .background(ListRowTracker(onHover: { hovering in
                if isHovered != hovering { isHovered = hovering }
            }))
    }
}

/// Turns off the native selection highlight of the enclosing table or outline
/// view, and reports when the pointer is over the whole row (including its
/// insets), so the hover rectangle follows the mouse without gaps between rows.
/// Selection, keyboard navigation and focus keep working.
private struct ListRowTracker: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.onHover = onHover
        nsView.attach()
    }

    static func dismantleNSView(_ nsView: TrackerView, coordinator: ()) {
        nsView.detach()
    }

    final class TrackerView: NSView {
        var onHover: (Bool) -> Void = { _ in }
        private weak var rowView: NSView?
        private var trackingArea: NSTrackingArea?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        func attach() {
            var row: NSView?
            var ancestor = superview
            while let view = ancestor {
                if row == nil, view is NSTableRowView { row = view }
                if let table = view as? NSTableView {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    break
                }
                ancestor = view.superview
            }
            guard let row, row !== rowView || trackingArea == nil else { return }
            detach()
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                      owner: self, userInfo: nil)
            row.addTrackingArea(area)
            rowView = row
            trackingArea = area
            // A row that appears under a resting pointer gets no mouseEntered.
            if let window = row.window {
                let point = row.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                let inside = row.bounds.contains(point)
                DispatchQueue.main.async { [weak self] in self?.onHover(inside) }
            }
        }

        func detach() {
            if let trackingArea { rowView?.removeTrackingArea(trackingArea) }
            trackingArea = nil
            rowView = nil
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
