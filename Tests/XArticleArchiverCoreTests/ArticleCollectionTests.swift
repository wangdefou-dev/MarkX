import Foundation
import SQLite3
import XCTest
@testable import XArticleArchiverCore

final class ArticleCollectionTests: XCTestCase {
    func testUpgradeAndReopenKeepCollectionsSeparateFromArchivedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "markx-collections-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "archive.sqlite")
        let seed = try ArchiveDatabase(url: url)
        let article = try await seedArticle(in: seed, root: root)
        try await seed.closeAfterCheckpointForDirectorySync()

        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        let legacySchema = sqlite3_exec(pointer, """
        DROP TABLE collection_articles;
        DROP TABLE collections;
        PRAGMA user_version=7;
        """, nil, nil, nil)
        XCTAssertEqual(sqlite3_close(pointer), SQLITE_OK)
        XCTAssertEqual(legacySchema, SQLITE_OK)

        let upgraded = try ArchiveDatabase(url: url)
        try await upgraded.createCollection(name: " 待读 ", articleID: article.id)
        try await upgraded.createCollection(name: "参考")
        let folders = try await upgraded.loadCollections()
        let reading = try XCTUnwrap(folders.first { $0.name == "待读" })
        let reference = try XCTUnwrap(folders.first { $0.name == "参考" })
        try await upgraded.setArticle(article.id, inCollection: reference.id, included: true)
        try await upgraded.setArticle(article.id, inCollection: reference.id, included: true)
        var refreshedArticle = article
        refreshedArticle.title = "同步后的文章标题"
        try await upgraded.upsertArticle(refreshedArticle)
        try await upgraded.closeAfterCheckpointForDirectorySync()

        let reopened = try ArchiveDatabase(url: url)
        let saved = try await reopened.loadCollections()
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.allSatisfy { $0.articleIDs == [article.id] })
        try await reopened.setArticle(article.id, inCollection: reading.id, included: false)
        let afterRemoval = try await reopened.loadCollections()
        XCTAssertEqual(afterRemoval.first { $0.id == reading.id }?.articleIDs, [])
        XCTAssertEqual(afterRemoval.first { $0.id == reference.id }?.articleIDs, [article.id])
        try await reopened.deleteCollection(id: reference.id)

        let remaining = try await reopened.loadCollections()
        XCTAssertEqual(remaining.map(\.id), [reading.id])
        let archived = try await reopened.article(sourcePostID: article.sourcePostID)
        XCTAssertEqual(archived?.id, article.id)
        XCTAssertEqual(archived?.title, refreshedArticle.title)
        let path = try XCTUnwrap(archived?.markdownPath)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "归档正文")
    }

    func testMissingArticleRollsBackCreationAndDeletingArticleClearsItsReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "markx-collections-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ArchiveDatabase(url: root.appending(path: "archive.sqlite"))
        do {
            try await database.createCollection(name: "参考", articleID: UUID())
            XCTFail("A missing article must not leave a partially created folder")
        } catch {}
        let folders = try await database.loadCollections()
        XCTAssertTrue(folders.isEmpty)

        let article = try await seedArticle(in: database, root: root)
        try await database.createCollection(name: "参考", articleID: article.id)
        try await database.deleteArticle(id: article.id)
        let remaining = try await database.loadCollections()
        XCTAssertEqual(remaining.map(\.name), ["参考"])
        XCTAssertEqual(remaining.first?.articleIDs, [])
    }

    private func seedArticle(in database: ArchiveDatabase, root: URL) async throws -> ArchivedArticle {
        let creator = Creator(xUserID: "writer", username: "writer", displayName: "作者")
        try await database.upsertCreator(creator)
        let markdown = root.appending(path: "article.md")
        try "归档正文".write(to: markdown, atomically: true, encoding: .utf8)
        let article = ArchivedArticle(
            stableSourceKey: "article", creatorID: creator.id, title: "原始文章", authorHandle: creator.username,
            contentType: .xArticle, sourceURL: URL(string: "https://x.com/writer/status/123")!,
            sourcePostID: "123", publishedAt: Date(), sourceChecksum: "source",
            markdownPath: markdown.path, pipelineState: .committed
        )
        try await database.upsertArticle(article)
        return article
    }
}
