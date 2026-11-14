import AppKit
import SwiftUI

/// Tracks a drag between the two lists in the same MarkX window.
@MainActor
final class CollectionDragController {
    enum Item {
        case article(UUID)
        case collection(UUID)
    }

    private struct Drag {
        let articleID: UUID
        let windowNumber: Int
        let origin: CGPoint
        var started = false
    }

    private let regions = NSHashTable<CollectionDragRegion.View>.weakObjects()
    private var monitor: Any?
    private var drag: Drag?
    private var target: UUID?

    func register(_ region: CollectionDragRegion.View) {
        regions.add(region)
    }

    func start(onTarget: @escaping (UUID?) -> Void, onDrop: @escaping (UUID, UUID) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            self?.handle(event, onTarget: onTarget, onDrop: onDrop)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        drag = nil
        target = nil
    }

    private func handle(_ event: NSEvent, onTarget: (UUID?) -> Void, onDrop: (UUID, UUID) -> Void) {
        switch event.type {
        case .leftMouseDown:
            clear(onTarget)
            if case let .article(articleID) = item(at: event, matchingArticle: true) {
                drag = Drag(articleID: articleID, windowNumber: event.windowNumber, origin: event.locationInWindow)
            }
        case .leftMouseDragged:
            guard var drag, drag.windowNumber == event.windowNumber else { return }
            if !drag.started {
                let location = event.locationInWindow
                guard hypot(location.x - drag.origin.x, location.y - drag.origin.y) >= 8 else { return }
                drag.started = true
                self.drag = drag
            }
            let newTarget = collection(at: event)
            if target != newTarget {
                target = newTarget
                onTarget(newTarget)
            }
        case .leftMouseUp:
            if let drag, drag.started, drag.windowNumber == event.windowNumber,
               let collectionID = collection(at: event) {
                onDrop(drag.articleID, collectionID)
            }
            clear(onTarget)
        case .keyDown where event.keyCode == 53:
            clear(onTarget)
        default:
            break
        }
    }

    private func clear(_ onTarget: (UUID?) -> Void) {
        drag = nil
        if target != nil {
            target = nil
            onTarget(nil)
        }
    }

    private func collection(at event: NSEvent) -> UUID? {
        guard case let .collection(id) = item(at: event, matchingArticle: false) else { return nil }
        return id
    }

    private func item(at event: NSEvent, matchingArticle: Bool) -> Item? {
        guard let window = event.window else { return nil }
        return regions.allObjects.first { region in
            guard region.window === window, !region.isHiddenOrHasHiddenAncestor else { return false }
            switch region.item {
            case .article where !matchingArticle, .collection where matchingArticle:
                return false
            default:
                return region.visibleRect.contains(region.convert(event.locationInWindow, from: nil))
            }
        }?.item
    }
}

struct CollectionDragRegion: NSViewRepresentable {
    let controller: CollectionDragController
    let item: CollectionDragController.Item

    func makeNSView(context: Context) -> View {
        let view = View(frame: .zero)
        view.item = item
        controller.register(view)
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        view.item = item
    }

    final class View: NSView {
        var item: CollectionDragController.Item?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
