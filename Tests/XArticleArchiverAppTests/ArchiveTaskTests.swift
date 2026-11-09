import Foundation
import XCTest
@testable import XArticleArchiverApp

@MainActor
final class ArchiveTaskTests: XCTestCase {
    func testStopDrainsRunningTasksAndRejectsAnOldBlockedEnqueue() async {
        let owner = ArticleArchiveTasks()
        var started = 0
        var ended = 0
        for _ in 0..<2 {
            await owner.schedule {
                started += 1
                try? await Task.sleep(for: .seconds(60))
                ended += 1
            }
        }
        while started < 2 { await Task.yield() }
        let blocked = Task { await owner.schedule { started += 1 } }
        await Task.yield()
        await owner.cancelAndWait()
        await blocked.value
        XCTAssertEqual(started, 2)
        XCTAssertEqual(ended, 2)
        XCTAssertEqual(owner.count, 0)
        await owner.schedule { ended += 1 }
        await owner.wait()
        XCTAssertEqual(ended, 3)
    }

    func testPartialDiscoveryIsExplicitlyDifferentFromCompleteDiscovery() {
        let partial = CreatorArticleDiscoveryResult(items: [], knownArticleCount: nil, isComplete: false)
        let complete = CreatorArticleDiscoveryResult(items: [], knownArticleCount: 0, confirmedEmpty: true)
        XCTAssertFalse(partial.isComplete)
        XCTAssertTrue(complete.isComplete)
        XCTAssertNotEqual(partial, complete)
    }
}
