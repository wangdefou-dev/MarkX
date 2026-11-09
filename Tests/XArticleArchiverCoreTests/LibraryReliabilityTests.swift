import Foundation
import XCTest
@testable import XArticleArchiverCore

final class LibraryReliabilityTests: XCTestCase {
    func testLongGrowingScanOutlivesTheOldPollLimitButStalledScanEnds() {
        var budget = CreatorArticleScanProgressBudget(limit: 3)
        for _ in 0..<500 {
            budget.beginPoll()
            budget.foundNewItems()
            XCTAssertFalse(budget.exhausted)
        }
        for _ in 0..<3 { budget.beginPoll() }
        XCTAssertTrue(budget.exhausted)
    }
    func testUPicUploadStopsItsProcessWhenCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "markx-upic-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "fake-upic")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let adapter = UPicAdapter(executableURL: executable, processTimeout: 60)
        let started = Date()
        let task = Task { try await adapter.upload(fileURLs: [root.appending(path: "image.png")]) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled upload must stop") }
        catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
    private func article() -> ArchivedArticle {
        ArchivedArticle(stableSourceKey: "search-123", creatorID: UUID(), title: "本地知识库管理",
            authorHandle: "example_writer", contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/123")!, sourcePostID: "123",
            publishedAt: Date(timeIntervalSince1970: 0), sourceChecksum: "test")
    }

    func testSearchSupportsChineseSubstringsAuthorPunctuationAndUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "markx-search-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ArchiveDatabase(url: root.appending(path: "archive.sqlite"))
        let item = article()
        try await database.indexArticle(item, body: "手工笔记和文章归档，保留 100% 原文。\nUse SwiftUI with SQLite.")
        for query in ["知识", "知识库", "工笔记", "example_writer", "swiftui", "100%", "\"", "%", "_"] {
            let matches = try await database.searchArticleIDs(query)
            if query == "\"" { XCTAssertTrue(matches.isEmpty) }
            else { XCTAssertEqual(matches, [item.id], query) }
        }
        try await database.indexArticle(item, body: "新正文")
        let oldMatches = try await database.searchArticleIDs("工笔记")
        XCTAssertTrue(oldMatches.isEmpty)
        let newMatches = try await database.searchArticleIDs("新正文")
        XCTAssertEqual(newMatches, [item.id])
        try await database.deleteArticle(id: item.id)
        let deleted = try await database.searchArticleIDs("知识库")
        XCTAssertTrue(deleted.isEmpty)
    }

    func testCommitFailureRollsBackSearchAndArticleTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "markx-search-rollback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ArchiveDatabase(url: root.appending(path: "archive.sqlite"))
        let item = article() // No creator: the FK failure must not leave an index entry.
        do {
            try await database.commitArticle(item, searchBody: "不可提交正文")
            XCTFail("Commit without an owner must fail")
        } catch { }
        let matches = try await database.searchArticleIDs("不可提交正文")
        let stored = try await database.article(stableSourceKey: item.stableSourceKey)
        XCTAssertTrue(matches.isEmpty)
        XCTAssertNil(stored)
    }

    func testCacheCleanupKeepsDifferentAndUniqueFilesAndSupportsOldSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "markx-cache-cleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: ".x-article-archiver/assets-cache")
        let media = root.appending(path: "media/images")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: cache.appending(path: "same.png"))
        try Data("same".utf8).write(to: media.appending(path: "same.png"))
        try Data("left".utf8).write(to: cache.appending(path: "different.png"))
        try Data("else".utf8).write(to: media.appending(path: "different.png"))
        try Data("unique".utf8).write(to: cache.appending(path: "unique.png"))
        let result = try MediaCacheMaintenance.removeVerifiedDuplicates(root: root)
        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertEqual(result.removedLogicalBytes, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appending(path: "different.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appending(path: "unique.png").path))
        XCTAssertEqual(MediaCacheMaintenance.availablePath(cache.appending(path: "same.png").path, root: root), media.appending(path: "same.png").path)
        XCTAssertEqual(try Data(contentsOf: media.appending(path: "same.png")), Data("same".utf8))
    }

    func testCacheCleanupDoesNotFollowSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "markx-cache-symlink-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: ".x-article-archiver/assets-cache")
        let media = root.appending(path: "media/images")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let outside = root.appending(path: "outside.png")
        try Data("same".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: cache.appending(path: "link.png"), withDestinationURL: outside)
        try Data("same".utf8).write(to: media.appending(path: "link.png"))
        XCTAssertEqual(try MediaCacheMaintenance.removeVerifiedDuplicates(root: root).removedFiles, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testCancellationBeforeCommitKeepsOldArchiveRecoverable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "markx-cancel-commit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ArchiveDatabase(url: root.appending(path: "archive.sqlite"))
        let creator = Creator(xUserID: "cancel-writer", username: "writer", displayName: "作者")
        try await database.upsertCreator(creator)
        let document = CanonicalDocument(title: "停止测试", authorName: "作者", authorHandle: "writer",
            contentType: .xArticle, sourceURL: URL(string: "https://x.com/writer/status/123")!,
            sourcePostID: "123", publishedAt: Date(timeIntervalSince1970: 0),
            blocks: [CanonicalBlock(kind: .paragraph, text: "完整正文")])
        let pipeline = ArchivePipeline(database: database, imageHost: LocalMediaHostAdapter(archiveRoot: root))
        let job = Task {
            try await pipeline.archive(document: document, creator: creator, root: root) { stage in
                if stage == "正在生成并校验 Markdown" {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await job.value; XCTFail("Cancelled work must not commit") }
        catch is CancellationError { }
        let record = try await database.article(sourcePostID: "123")
        XCTAssertNotEqual(record?.pipelineState, .committed)
        XCTAssertNil(record?.markdownPath)
    }
}
