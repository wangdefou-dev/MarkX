import XCTest
@testable import XArticleArchiverApp

final class SplitColumnLayoutTests: XCTestCase {
    private let columns = [SplitColumnLayout.sidebar, SplitColumnLayout.list]

    func testRestoresIdealWidthsWhenFirstLaunchSqueezesLeadingColumns() {
        // Observed on a fresh macOS 27 install: 145pt sidebar, 185pt list.
        let widths = SplitColumnLayout.correctedWidths(
            widths: [145, 185], columns: columns, availableWidth: 1_358
        )
        XCTAssertEqual(widths, [SplitColumnLayout.sidebar.ideal, SplitColumnLayout.list.ideal])
    }

    func testLeavesWidthsInsideTheirRangeUntouched() {
        XCTAssertNil(SplitColumnLayout.correctedWidths(
            widths: [260, 400], columns: columns, availableWidth: 1_358
        ))
    }

    func testCapsListThatGrewPastItsMaximumWhenSidebarIsHidden() {
        let widths = SplitColumnLayout.correctedWidths(
            widths: [767], columns: [SplitColumnLayout.list], availableWidth: 1_359
        )
        XCTAssertEqual(widths, [SplitColumnLayout.list.max])
    }

    func testNarrowWindowKeepsMinimumsAndGivesTheRestToDetail() {
        let widths = SplitColumnLayout.correctedWidths(
            widths: [100, 100], columns: columns, availableWidth: 1_078
        )
        XCTAssertEqual(widths, [248, 390])
        XCTAssertGreaterThanOrEqual(1_078 - (widths ?? []).reduce(0, +), SplitColumnLayout.detailMinimum)
    }

    func testRejectsMismatchedInput() {
        XCTAssertNil(SplitColumnLayout.correctedWidths(widths: [100], columns: columns, availableWidth: 1_200))
    }
}
