import Foundation
import XCTest
@testable import XArticleArchiverApp

final class CollectionArticleDragTests: XCTestCase {
    @MainActor
    func testDropReceivesArticleIDFromSameProcessProvider() async {
        let articleID = UUID()
        let received = expectation(description: "Receives the dragged article ID")
        let provider = CollectionArticleDrag.provider(for: articleID)

        XCTAssertTrue(CollectionArticleDrag.receive([provider]) { id in
            XCTAssertEqual(id, articleID)
            received.fulfill()
        })
        await fulfillment(of: [received], timeout: 2)
    }

    @MainActor
    func testDropRejectsUnrelatedData() {
        let provider = NSItemProvider(object: "unrelated" as NSString)
        XCTAssertFalse(CollectionArticleDrag.receive([provider]) { _ in
            XCTFail("Drop accepted data from an unrelated item provider")
        })
    }
}
