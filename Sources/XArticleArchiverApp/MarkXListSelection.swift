import AppKit
import SwiftUI

/// Fog-style list selection: a quiet rounded rectangle behind the selected row
/// instead of the system highlight. The accent-blue highlight of a focused
/// list made grey secondary text unreadable, and the sidebar's own highlight
/// was too faint to see; one drawn background keeps text colours intact and
/// looks the same whether or not the list has focus.
extension View {
    func markxSelectableRow(isSelected: Bool, horizontalInset: CGFloat = MarkXSpace.m) -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: MarkXRadius.card)
                .fill(isSelected ? MarkXInterface.selection : Color.clear)
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, 1)
        )
        .background(ListHighlightSuppressor())
    }
}

/// Turns off the native selection highlight of the enclosing table or outline
/// view. Selection, keyboard navigation and focus keep working.
private struct ListHighlightSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> SuppressorView { SuppressorView() }
    func updateNSView(_ nsView: SuppressorView, context: Context) { nsView.apply() }

    final class SuppressorView: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                    }
                    return
                }
                ancestor = view.superview
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
