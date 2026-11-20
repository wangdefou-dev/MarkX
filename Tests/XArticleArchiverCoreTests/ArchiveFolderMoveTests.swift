import Foundation
import XCTest
@testable import XArticleArchiverCore

final class ArchiveFolderMoveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "markx-move-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Changing the archive folder moves the data: after a verified copy the
    /// old folder is emptied (to the Trash in the app) and removed.
    func testMoveLeavesNothingBehindInOldFolder() throws {
        let source = root.appending(path: "old")
        let destination = root.appending(path: "new")
        let article = source.appending(path: "Blogger/@writer/articles/a.md")
        try FileManager.default.createDirectory(at: article.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# 正文".write(to: article, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: source.appending(path: "media/images"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: source.appending(path: "media/images/p.png"))
        try FileManager.default.createDirectory(at: source.appending(path: ".x-article-archiver"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: source.appending(path: ".x-article-archiver/archive.sqlite"))

        _ = try ArchiveDirectorySynchronizer.synchronize(from: source, to: destination)
        var discarded: [String] = []
        let removed = try ArchiveDirectorySynchronizer.removeSourceAfterMove(source, destination: destination) { url in
            discarded.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }

        XCTAssertEqual(removed, 3)
        XCTAssertEqual(Set(discarded), ["Blogger", "media", ".x-article-archiver"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "Blogger/@writer/articles/a.md"), encoding: .utf8), "# 正文")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "media/images/p.png").path))
    }

    func testRefusesToEmptyAFolderThatContainsTheDestination() throws {
        let source = root.appending(path: "old")
        try FileManager.default.createDirectory(at: source.appending(path: "inner"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try ArchiveDirectorySynchronizer.removeSourceAfterMove(
            source, destination: source.appending(path: "inner")) { _ in XCTFail("must not discard") })
        XCTAssertThrowsError(try ArchiveDirectorySynchronizer.removeSourceAfterMove(
            source, destination: source) { _ in XCTFail("must not discard") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
