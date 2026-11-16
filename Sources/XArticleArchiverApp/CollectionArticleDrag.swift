import AppKit
import SwiftUI

@MainActor
final class CollectionArticleDrag {
    private let destinations = NSHashTable<CollectionDropRegion.View>.weakObjects()
    private weak var source: CollectionDragSource.View?
    private var preview: PreviewView?
    private var target: UUID?

    func register(_ destination: CollectionDropRegion.View) {
        destinations.add(destination)
    }

    func move(from source: CollectionDragSource.View, to point: CGPoint) {
        guard let content = source.window?.contentView else { return }
        if self.source !== source {
            cancel()
            self.source = source
        }
        if preview == nil {
            let view = PreviewView(rootView: CollectionArticleDragPreview(title: source.title))
            view.setFrameSize(view.fittingSize)
            content.addSubview(view, positioned: .above, relativeTo: nil)
            preview = view
        }
        if let preview {
            let location = content.convert(point, from: nil)
            let bounds = content.bounds.insetBy(dx: 6, dy: 6)
            let size = preview.frame.size
            let x = location.x + 14 + size.width <= bounds.maxX ? location.x + 14 : location.x - 14 - size.width
            let y = content.isFlipped ? location.y + 14 : location.y - 14 - size.height
            preview.setFrameOrigin(CGPoint(x: max(bounds.minX, min(x, bounds.maxX - size.width)),
                                           y: max(bounds.minY, min(y, bounds.maxY - size.height))))
        }
        let next = destination(at: point, in: source.window)
        if next != target {
            target = next
            source.onTarget(next)
        }
    }

    func end(from source: CollectionDragSource.View, at point: CGPoint) {
        guard self.source === source else { return }
        let destination = destination(at: point, in: source.window)
        cancel()
        if let destination { source.onDrop(destination) }
    }

    func cancel(from view: CollectionDragSource.View? = nil) {
        if let view, source !== view { return }
        if target != nil { source?.onTarget(nil) }
        target = nil
        source = nil
        preview?.removeFromSuperview()
        preview = nil
    }

    private func destination(at point: CGPoint, in window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        let visibleRegions: [(UUID, CGRect)] = destinations.allObjects.compactMap { region in
            guard let id = region.collectionID, region.window === window,
                  !region.isHiddenOrHasHiddenAncestor else { return nil }
            return (id, region.convert(region.visibleRect, to: nil))
        }
        return Self.target(at: point, in: visibleRegions)
    }

    nonisolated static func target(at point: CGPoint, in visibleRegions: [(UUID, CGRect)]) -> UUID? {
        visibleRegions.first { _, frame in frame.contains(point) }?.0
    }

    private final class PreviewView: NSHostingView<CollectionArticleDragPreview> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct CollectionDropRegion: NSViewRepresentable {
    let collectionID: UUID
    let controller: CollectionArticleDrag

    func makeNSView(context: Context) -> View {
        let view = View(frame: .zero)
        controller.register(view)
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        view.collectionID = collectionID
    }

    final class View: NSView {
        var collectionID: UUID?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct CollectionDragSource: NSViewRepresentable {
    let controller: CollectionArticleDrag
    let title: String
    let onSelect: () -> Void
    let canDrag: () -> Bool
    let onTarget: (UUID?) -> Void
    let onDrop: (UUID) -> Void

    func makeNSView(context: Context) -> View { View(frame: .zero) }

    func updateNSView(_ view: View, context: Context) {
        view.controller = controller
        view.title = title
        view.onSelect = onSelect
        view.canDrag = canDrag
        view.onTarget = onTarget
        view.onDrop = onDrop
    }

    static func dismantleNSView(_ view: View, coordinator: ()) {
        view.controller?.cancel(from: view)
    }

    final class View: NSView {
        weak var controller: CollectionArticleDrag?
        var title = ""
        var onSelect: () -> Void = {}
        var canDrag: () -> Bool = { false }
        var onTarget: (UUID?) -> Void = { _ in }
        var onDrop: (UUID) -> Void = { _ in }
        private var origin: CGPoint?
        private var dragging = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Secondary clicks still reach the SwiftUI row and its context menu.
            guard NSApp.currentEvent?.type == .leftMouseDown,
                  NSApp.currentEvent?.modifierFlags.contains(.control) != true else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            controller?.cancel(from: self)
            origin = event.locationInWindow
            dragging = false
            onSelect()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin, canDrag() else { return }
            let point = event.locationInWindow
            guard dragging || hypot(point.x - origin.x, point.y - origin.y) >= 8 else { return }
            dragging = true
            controller?.move(from: self, to: point)
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                dragging = false
                origin = nil
            }
            if dragging, canDrag() {
                controller?.end(from: self, at: event.locationInWindow)
            } else {
                controller?.cancel(from: self)
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { controller?.cancel(from: self) }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

struct CollectionArticleDragPreview: View {
    let title: String

    var body: some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: "doc.text.fill").foregroundStyle(Color.orange)
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 204, height: 32, alignment: .leading)
        .padding(.horizontal, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.75)) }
        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
        .padding(5)
        .accessibilityHidden(true)
    }
}
