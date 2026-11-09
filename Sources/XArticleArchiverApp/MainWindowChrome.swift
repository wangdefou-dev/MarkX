import AppKit
import SwiftUI

/// Keeps the product name and sidebar control beside the native window controls,
/// independent of column visibility and toolbar overflow.
struct MainWindowChrome: NSViewRepresentable {
    var isSidebarVisible: Bool
    var toggleSidebar: () -> Void

    func makeNSView(context: Context) -> WindowAnchor {
        let anchor = WindowAnchor()
        anchor.isSidebarVisible = isSidebarVisible
        anchor.toggleSidebar = toggleSidebar
        return anchor
    }

    func updateNSView(_ nsView: WindowAnchor, context: Context) {
        nsView.isSidebarVisible = isSidebarVisible
        nsView.toggleSidebar = toggleSidebar
        nsView.configureWindow()
    }

    final class WindowAnchor: NSView {
        var isSidebarVisible = true
        var toggleSidebar: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.titlebarSeparatorStyle = .line
            let accessory: ProductTitleAccessory
            if let existing = window.titlebarAccessoryViewControllers.first(where: { $0 is ProductTitleAccessory }) as? ProductTitleAccessory {
                accessory = existing
            } else {
                accessory = ProductTitleAccessory()
                accessory.layoutAttribute = .left
                window.addTitlebarAccessoryViewController(accessory)
            }
            accessory.configure(isSidebarVisible: isSidebarVisible, toggleSidebar: toggleSidebar)
        }
    }
}

private final class ProductTitleAccessory: NSTitlebarAccessoryViewController {
    private let sidebarButton = NSButton()
    private var toggleSidebar: (() -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 104, height: 28))
        let label = NSTextField(labelWithString: "MarkX")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        sidebarButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        sidebarButton.imagePosition = .imageOnly
        sidebarButton.imageScaling = .scaleProportionallyDown
        sidebarButton.bezelStyle = .texturedRounded
        sidebarButton.isBordered = false
        sidebarButton.contentTintColor = .labelColor
        sidebarButton.target = self
        sidebarButton.action = #selector(toggleSidebarClicked)
        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(sidebarButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: sidebarButton.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            sidebarButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            sidebarButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            sidebarButton.widthAnchor.constraint(equalToConstant: 28),
            sidebarButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        view = container
    }

    func configure(isSidebarVisible: Bool, toggleSidebar: (() -> Void)?) {
        _ = view
        self.toggleSidebar = toggleSidebar
        let actionTitle = isSidebarVisible ? "隐藏侧边栏" : "显示侧边栏"
        sidebarButton.toolTip = actionTitle
        sidebarButton.setAccessibilityLabel(actionTitle)
    }

    @objc private func toggleSidebarClicked() {
        toggleSidebar?()
    }
}
