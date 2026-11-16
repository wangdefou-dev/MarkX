import Foundation
import XCTest
@testable import XArticleArchiverApp

final class CollectionArticleDragTests: XCTestCase {
    func testDropChoosesTheCollectionUnderThePointer() {
        let first = UUID()
        let second = UUID()
        let visibleRows = [
            (first, CGRect(x: 16, y: 180, width: 200, height: 27)),
            (second, CGRect(x: 16, y: 215, width: 200, height: 27))
        ]

        XCTAssertEqual(CollectionArticleDrag.target(at: CGPoint(x: 200, y: 226), in: visibleRows), second)
        XCTAssertNil(CollectionArticleDrag.target(at: CGPoint(x: 200, y: 211), in: visibleRows))
    }

    func testDropIgnoresTheClippedPartOfACollectionRow() {
        let collection = UUID()
        let visibleRows = [(collection, CGRect(x: 16, y: 50, width: 200, height: 17))]

        XCTAssertNil(CollectionArticleDrag.target(at: CGPoint(x: 100, y: 45), in: visibleRows))
        XCTAssertEqual(CollectionArticleDrag.target(at: CGPoint(x: 100, y: 60), in: visibleRows), collection)
    }
}
