import AppKit
import SwiftUI

/// Keeps the product name and sidebar control beside the native window controls,
/// independent of column visibility and toolbar overflow.
struct MainWindowChrome: NSViewRepresentable {
    var isSidebarVisible: Bool
    var trailingListTitle: String? = nil
    var toggleSidebar: () -> Void

    func makeNSView(context: Context) -> WindowAnchor {
        let anchor = WindowAnchor()
        anchor.isSidebarVisible = isSidebarVisible
        anchor.trailingListTitle = trailingListTitle
        anchor.toggleSidebar = toggleSidebar
        return anchor
    }

    func updateNSView(_ nsView: WindowAnchor, context: Context) {
        nsView.isSidebarVisible = isSidebarVisible
        nsView.trailingListTitle = trailingListTitle
        nsView.toggleSidebar = toggleSidebar
        nsView.configureWindow()
    }

    final class WindowAnchor: NSView {
        var isSidebarVisible = true
        var trailingListTitle: String?
        var toggleSidebar: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if window != nil {
                // A sidebar transition can move the column without changing
                // this background view's own frame.
                var ancestor: NSView? = self
                while let view = ancestor {
                    view.postsFrameChangedNotifications = true
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(columnGeometryDidChange),
                        name: NSView.frameDidChangeNotification, object: view
                    )
                    ancestor = view.superview
                }
            }
            configureWindow()
        }

        @objc private func columnGeometryDidChange() {
            needsLayout = true
        }

        override func layout() {
            super.layout()
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
            accessory.configure(
                isSidebarVisible: isSidebarVisible,
                trailingListTitle: trailingListTitle,
                listTrailingX: convert(bounds, to: nil).maxX,
                toggleSidebar: toggleSidebar
            )
        }
    }
}

private final class ProductTitleAccessory: NSTitlebarAccessoryViewController {
    private let sidebarButton = NSButton()
    private let listTitle = NSTextField(labelWithString: "")
    private var listTitleLeadingConstraint: NSLayoutConstraint?
    private var toggleSidebar: (() -> Void)?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 116, height: 36))
        let label = NSTextField(labelWithString: "MarkX")
        label.font = .systemFont(ofSize: MarkXTypography.pointSize(13), weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        sidebarButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        sidebarButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        sidebarButton.imagePosition = .imageOnly
        sidebarButton.imageScaling = .scaleProportionallyDown
        sidebarButton.bezelStyle = .circular
        sidebarButton.controlSize = .large
        sidebarButton.isBordered = true
        sidebarButton.contentTintColor = .labelColor
        sidebarButton.target = self
        sidebarButton.action = #selector(toggleSidebarClicked)
        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        listTitle.font = .systemFont(ofSize: MarkXTypography.pointSize(13), weight: .semibold)
        listTitle.textColor = .labelColor
        listTitle.alignment = .right
        listTitle.lineBreakMode = .byTruncatingTail
        listTitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(sidebarButton)
        container.addSubview(listTitle)
        listTitleLeadingConstraint = listTitle.leadingAnchor.constraint(
            greaterThanOrEqualTo: sidebarButton.trailingAnchor, constant: 16
        )
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: sidebarButton.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            sidebarButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 72),
            sidebarButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            sidebarButton.widthAnchor.constraint(equalToConstant: 36),
            sidebarButton.heightAnchor.constraint(equalToConstant: 32),
            listTitle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            listTitle.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container
    }

    func configure(isSidebarVisible: Bool, trailingListTitle: String?, listTrailingX: CGFloat,
                   toggleSidebar: (() -> Void)?) {
        _ = view
        self.toggleSidebar = toggleSidebar
        let actionTitle = isSidebarVisible ? "隐藏侧边栏" : "显示侧边栏"
        sidebarButton.toolTip = actionTitle
        sidebarButton.setAccessibilityLabel(actionTitle)
        listTitle.stringValue = trailingListTitle ?? ""
        listTitle.isHidden = trailingListTitle == nil
        listTitleLeadingConstraint?.isActive = trailingListTitle != nil
        // Measure the actual column edge in window coordinates so the title
        // follows split-view resizing without shifting the product controls.
        let width = trailingListTitle == nil ? 116 : max(116, listTrailingX - view.convert(.zero, to: nil).x)
        if abs(view.frame.width - width) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
        }
    }

    @objc private func toggleSidebarClicked() {
        toggleSidebar?()
    }
}
