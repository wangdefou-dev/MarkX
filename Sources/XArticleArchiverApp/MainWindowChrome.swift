import AppKit
import QuartzCore
import SwiftUI

/// Keeps the product name beside the native window controls and anchors the
/// sidebar control to the expanded sidebar's trailing edge, outside overflow.
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
    private var pendingSidebarTransition = false
    private var chromeAnimationEndsAt: CFTimeInterval = 0
    private var targetButtonFrame: NSRect?
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
        sidebarButton.frame = NSRect(x: 72, y: 2, width: 36, height: 32)
        sidebarButton.wantsLayer = true
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
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
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

        if let previousSidebarVisibility, previousSidebarVisibility != isSidebarVisible {
            pendingSidebarTransition = true
        }
        previousSidebarVisibility = isSidebarVisible
        listTitle.stringValue = libraryTitle ?? ""
        listTitle.isHidden = libraryTitle == nil
        // SwiftUI updates visibility before the split view moves. Keep the same
        // controls in place until the column reports its new frame.
        let columnHasMoved = isSidebarVisible ? listFrame.minX > 0.5 : listFrame.minX <= 0.5
        if pendingSidebarTransition && !columnHasMoved { return }

        let accessoryX = view.convert(.zero, to: nil).x
        // Creator headings use the native toolbar, but their sidebar control
        // still needs a container covering the expanded sidebar for hit testing.
        let trailingX = libraryTitle != nil ? listFrame.maxX
            : isSidebarVisible ? listFrame.minX : accessoryX + 116
        let width = max(116, trailingX - accessoryX)
        if abs(view.frame.width - width) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
        }

        let buttonX = isSidebarVisible ? max(72, listFrame.minX - accessoryX - 8 - 36) : 72
        let buttonFrame = NSRect(x: buttonX, y: (view.bounds.height - 32) / 2,
                                 width: 36, height: 32)
        let titleFrame: NSRect?
        if libraryTitle != nil {
            let size = listTitle.cell?.cellSize ?? listTitle.intrinsicContentSize
            let leadingX = max(124, listFrame.minX - accessoryX + 16)
            let titleWidth = min(ceil(size.width), max(0, width - 16 - (isSidebarVisible ? leadingX : 124)))
            let x = isSidebarVisible ? leadingX : width - 16 - titleWidth
            titleFrame = NSRect(x: x, y: (view.bounds.height - size.height) / 2,
                                width: titleWidth, height: size.height)
        } else {
            titleFrame = nil
        }
        let now = CACurrentMediaTime()
        if pendingSidebarTransition {
            chromeAnimationEndsAt = now + MainWindowChrome.sidebarTransitionDuration
            pendingSidebarTransition = false
        }
        let buttonChanged = targetButtonFrame != buttonFrame
        let titleChanged = targetTitleFrame != titleFrame
        let animateButton = targetButtonFrame != nil && now < chromeAnimationEndsAt
        let animateTitle = targetTitleFrame != nil && now < chromeAnimationEndsAt
        targetButtonFrame = buttonFrame
        targetTitleFrame = titleFrame
        guard buttonChanged || titleChanged else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = max(0, chromeAnimationEndsAt - now)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if buttonChanged {
                if animateButton {
                    sidebarButton.animator().frame = buttonFrame
                } else {
                    sidebarButton.frame = buttonFrame
                }
            }
            if titleChanged, let titleFrame {
                if animateTitle {
                    listTitle.animator().frame = titleFrame
                } else {
                    listTitle.frame = titleFrame
                }
            }
        }
    }

    @objc private func toggleSidebarClicked() {
        toggleSidebar?()
    }
}
