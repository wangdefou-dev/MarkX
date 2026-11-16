import Foundation
import XCTest
@testable import XArticleArchiverApp

final class CollectionArticleDragTests: XCTestCase {
    private let sidebar = CGRect(x: 0, y: 50, width: 240, height: 500)

    func testDropChoosesTheCollectionUnderThePointer() {
        let first = UUID()
        let second = UUID()
        let collections = [
            first: CGRect(x: 16, y: 180, width: 200, height: 27),
            second: CGRect(x: 16, y: 215, width: 200, height: 27)
        ]

        XCTAssertEqual(CollectionArticleDrag.target(at: CGPoint(x: 200, y: 226), sidebar: sidebar, collections: collections), second)
        XCTAssertNil(CollectionArticleDrag.target(at: CGPoint(x: 200, y: 211), sidebar: sidebar, collections: collections))
    }

    func testDropIgnoresTheClippedPartOfACollectionRow() {
        let collections = [UUID(): CGRect(x: 16, y: 40, width: 200, height: 27)]

        XCTAssertNil(CollectionArticleDrag.target(at: CGPoint(x: 100, y: 45), sidebar: sidebar, collections: collections))
    }
}
