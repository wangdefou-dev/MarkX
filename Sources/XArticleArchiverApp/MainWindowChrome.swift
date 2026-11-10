import AppKit
import QuartzCore
import SwiftUI

/// Keeps the product name and sidebar control beside the native window controls,
/// independent of column visibility and toolbar overflow.
struct MainWindowChrome: NSViewRepresentable {
    static let sidebarTransitionDuration = 0.28

    var isSidebarVisible: Bool
    var libraryTitle: String? = nil
    var toggleSidebar: () -> Void

    func makeNSView(context: Context) -> WindowAnchor {
        let anchor = WindowAnchor()
        anchor.isSidebarVisible = isSidebarVisible
        anchor.libraryTitle = libraryTitle
        anchor.toggleSidebar = toggleSidebar
        return anchor
    }

    func updateNSView(_ nsView: WindowAnchor, context: Context) {
        nsView.isSidebarVisible = isSidebarVisible
        nsView.libraryTitle = libraryTitle
        nsView.toggleSidebar = toggleSidebar
        nsView.configureWindow()
    }

    final class WindowAnchor: NSView {
        var isSidebarVisible = true
        var libraryTitle: String?
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
                libraryTitle: libraryTitle,
                listFrame: convert(bounds, to: nil),
                toggleSidebar: toggleSidebar
            )
        }
    }
}

private final class ProductTitleAccessory: NSTitlebarAccessoryViewController {
    private let sidebarButton = NSButton()
    private let listTitle = NSTextField(labelWithString: "")
    private var previousSidebarVisibility: Bool?
    private var pendingTitleTransition = false
    private var titleAnimationEndsAt: CFTimeInterval = 0
    private var targetTitleFrame: NSRect?
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
        // Match the native navigation title in both sidebar states.
        listTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        listTitle.textColor = .labelColor
        listTitle.alignment = .right
        listTitle.lineBreakMode = .byTruncatingTail
        listTitle.maximumNumberOfLines = 1
        listTitle.wantsLayer = true
        container.addSubview(label)
        container.addSubview(sidebarButton)
        container.addSubview(listTitle)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: sidebarButton.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            sidebarButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 72),
            sidebarButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            sidebarButton.widthAnchor.constraint(equalToConstant: 36),
            sidebarButton.heightAnchor.constraint(equalToConstant: 32)
        ])
        view = container
    }

    func configure(isSidebarVisible: Bool, libraryTitle: String?, listFrame: NSRect,
                   toggleSidebar: (() -> Void)?) {
        _ = view
        self.toggleSidebar = toggleSidebar
        let actionTitle = isSidebarVisible ? "隐藏侧边栏" : "显示侧边栏"
        sidebarButton.toolTip = actionTitle
        sidebarButton.setAccessibilityLabel(actionTitle)

        if let previousSidebarVisibility, previousSidebarVisibility != isSidebarVisible,
           !listTitle.isHidden {
            pendingTitleTransition = true
        }
        previousSidebarVisibility = isSidebarVisible
        listTitle.stringValue = libraryTitle ?? ""
        listTitle.isHidden = libraryTitle == nil
        guard libraryTitle != nil else {
            pendingTitleTransition = false
            targetTitleFrame = nil
            view.setFrameSize(NSSize(width: 116, height: view.frame.height))
            return
        }

        // SwiftUI updates visibility before the split view moves. Keep the same
        // title at its current position until the column reports its new frame.
        let columnHasMoved = isSidebarVisible ? listFrame.minX > 0.5 : listFrame.minX <= 0.5
        if pendingTitleTransition && !columnHasMoved { return }

        let accessoryX = view.convert(.zero, to: nil).x
        let width = max(116, listFrame.maxX - accessoryX)
        if abs(view.frame.width - width) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
        }
        let size = listTitle.cell?.cellSize ?? listTitle.intrinsicContentSize
        let titleWidth = min(ceil(size.width), max(0, width - 140))
        let leadingX = max(124, listFrame.minX - accessoryX + 16)
        let x = isSidebarVisible ? leadingX : width - 16 - titleWidth
        let frame = NSRect(x: x, y: (view.bounds.height - size.height) / 2,
                           width: titleWidth, height: size.height)
        let now = CACurrentMediaTime()
        if pendingTitleTransition {
            titleAnimationEndsAt = now + MainWindowChrome.sidebarTransitionDuration
            pendingTitleTransition = false
        }
        guard targetTitleFrame != frame else { return }
        let shouldAnimate = targetTitleFrame != nil && now < titleAnimationEndsAt
        targetTitleFrame = frame
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = titleAnimationEndsAt - now
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                listTitle.animator().setFrameOrigin(frame.origin)
                listTitle.animator().setFrameSize(frame.size)
            }
        } else {
            listTitle.frame = frame
        }
    }

    @objc private func toggleSidebarClicked() {
        toggleSidebar?()
    }
}
