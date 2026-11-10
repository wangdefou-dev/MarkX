import AppKit
import XCTest
@testable import XArticleArchiverApp

@MainActor
final class MainWindowChromeTests: XCTestCase {
    func testRepeatedWindowUpdatesKeepOneSidebarControl() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let anchor = MainWindowChrome.WindowAnchor()
        window.contentView = anchor
        anchor.configureWindow()
        anchor.configureWindow()

        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        let controls = window.titlebarAccessoryViewControllers.first?.view.subviews.compactMap { $0 as? NSButton } ?? []
        XCTAssertEqual(controls.count, 1)
        let button = try XCTUnwrap(controls.first)
        window.contentView?.layoutSubtreeIfNeeded()
        window.titlebarAccessoryViewControllers.first?.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(button.frame.width, 36)
        XCTAssertGreaterThanOrEqual(button.frame.height, 32)
        XCTAssertEqual(button.controlSize, .large)
        XCTAssertEqual(button.accessibilityLabel(), "隐藏侧边栏")
        XCTAssertEqual(window.titlebarAccessoryViewControllers.first?.layoutAttribute, .left)
    }

    func testHiddenSidebarControlUsesCurrentActionAndLabel() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let anchor = MainWindowChrome.WindowAnchor()
        var actions: [String] = []
        anchor.toggleSidebar = { actions.append("old") }
        window.contentView = anchor
        anchor.isSidebarVisible = false
        anchor.toggleSidebar = { actions.append("current") }
        anchor.configureWindow()

        let button = try XCTUnwrap(window.titlebarAccessoryViewControllers.first?.view.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(button.accessibilityLabel(), "显示侧边栏")
        XCTAssertEqual(button.toolTip, "显示侧边栏")
        button.performClick(nil)
        XCTAssertEqual(actions, ["current"])
    }

    func testSidebarTransitionPreservesTitleAndFontUntilColumnMoves() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 680))
        let anchor = MainWindowChrome.WindowAnchor(frame: NSRect(x: 235, y: 0, width: 430, height: 680))
        anchor.libraryTitle = "全部文章"
        content.addSubview(anchor)
        window.contentView = content
        anchor.configureWindow()
        let accessory = try XCTUnwrap(window.titlebarAccessoryViewControllers.first)
        let title = try XCTUnwrap(accessory.view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "全部文章" })
        let font = try XCTUnwrap(title.font)
        let expandedFrame = title.frame

        anchor.isSidebarVisible = false
        anchor.configureWindow()
        XCTAssertEqual(title.frame, expandedFrame, "Visibility updates must not jump ahead of the split view")
        XCTAssertFalse(title.isHidden)

        anchor.setFrameOrigin(.zero)
        anchor.configureWindow()
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertTrue(title.superview === accessory.view)
        XCTAssertEqual(title.font, font)
        XCTAssertEqual(font.pointSize, 15)
        XCTAssertGreaterThanOrEqual(title.bounds.width, try XCTUnwrap(title.cell).cellSize.width)
        XCTAssertEqual(title.convert(title.bounds, to: nil).maxX, 414, accuracy: 0.5)

        anchor.isSidebarVisible = true
        anchor.configureWindow()
        anchor.setFrameOrigin(NSPoint(x: 235, y: 0))
        anchor.configureWindow()
        try await Task.sleep(for: .seconds(0.4))
        XCTAssertEqual(title.frame, expandedFrame)
        XCTAssertEqual(title.font, font)
        XCTAssertFalse(title.isHidden)
    }
}
