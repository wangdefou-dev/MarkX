import AppKit
import SwiftUI

/// Keeps the product name next to the native window controls, independent of
/// the current library title and sidebar visibility.
struct MainWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowAnchor { WindowAnchor() }

    func updateNSView(_ nsView: WindowAnchor, context: Context) {
        nsView.configureWindow()
    }

    final class WindowAnchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.titlebarSeparatorStyle = .line
            guard !window.titlebarAccessoryViewControllers.contains(where: { $0 is ProductTitleAccessory }) else { return }
            let accessory = ProductTitleAccessory()
            accessory.layoutAttribute = .left
            window.addTitlebarAccessoryViewController(accessory)
        }
    }
}

private final class ProductTitleAccessory: NSTitlebarAccessoryViewController {
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 72, height: 28))
        let label = NSTextField(labelWithString: "MarkX")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container
    }
}
