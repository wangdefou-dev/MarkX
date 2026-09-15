import XCTest
@testable import XArticleArchiverApp

final class MarkXWindowPolicyTests: XCTestCase {
    func testClosesExtraMainLibraryWindowsAndKeepsThePreferredOne() {
        let windows = [
            MarkXWindowPolicy.Snapshot(title: "MarkX"),
            MarkXWindowPolicy.Snapshot(title: "MarkX 下载进度"),
            MarkXWindowPolicy.Snapshot(title: "MarkX"),
            MarkXWindowPolicy.Snapshot(title: "设置")
        ]

        XCTAssertEqual(
            MarkXWindowPolicy.duplicateMainWindowIndexes(in: windows, preferredIndex: 0),
            [2]
        )
    }

    func testDoesNotTreatProgressOrSettingsWindowsAsMainLibraryWindows() {
        let windows = [
            MarkXWindowPolicy.Snapshot(title: "MarkX"),
            MarkXWindowPolicy.Snapshot(title: "MarkX 下载进度"),
            MarkXWindowPolicy.Snapshot(title: "Settings")
        ]

        XCTAssertEqual(
            MarkXWindowPolicy.duplicateMainWindowIndexes(in: windows, preferredIndex: 0),
            []
        )
    }

    func testClosesRestoredDuplicateProgressWindows() {
        let windows = [
            MarkXWindowPolicy.Snapshot(title: "MarkX"),
            MarkXWindowPolicy.Snapshot(title: "MarkX 下载进度"),
            MarkXWindowPolicy.Snapshot(title: "MarkX 下载进度")
        ]

        XCTAssertEqual(
            MarkXWindowPolicy.duplicateProgressWindowIndexes(in: windows, preferredIndex: 1),
            [2]
        )
    }

    func testIgnoresPanelsAndSheetsWhenSelectingTheMainLibraryWindow() {
        let windows = [
            MarkXWindowPolicy.Snapshot(title: "MarkX", isPanel: true),
            MarkXWindowPolicy.Snapshot(title: "MarkX", hasSheetParent: true),
            MarkXWindowPolicy.Snapshot(title: "MarkX", isTitled: false),
            MarkXWindowPolicy.Snapshot(title: "MarkX")
        ]

        XCTAssertTrue(MarkXWindowPolicy.isMainLibraryWindow(windows[3]))
        XCTAssertEqual(
            MarkXWindowPolicy.duplicateMainWindowIndexes(in: windows, preferredIndex: 3),
            []
        )
    }

    func testScheduledSyncURLIsClaimedByTheExistingWindow() {
        let url = URL(string: "xarticlearchiver://scheduled-sync")

        XCTAssertEqual(url?.scheme, "xarticlearchiver")
        XCTAssertEqual(url?.host, "scheduled-sync")
        XCTAssertTrue(MarkXWindowPolicy.externalEventKeys.contains(url?.host ?? ""))
    }
}
