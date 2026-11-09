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
        let button = try XCTUnwrap(window.titlebarAccessoryViewControllers.first?.view.subviews.compactMap { $0 as? NSButton }.first)
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
}
