import Foundation
import SQLite3
import XCTest
@testable import XArticleArchiverCore

final class DatabaseDiskFailureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "markx-db-disk-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        MarkXLog.directory = root.appending(path: "logs")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLocalDiskKeepsWALMode() async throws {
        let database = try ArchiveDatabase(url: root.appending(path: ".x-article-archiver/archive.sqlite"))
        let mode = await database.journalMode
        XCTAssertEqual(mode, "wal")
        XCTAssertFalse(database.location.prefersRollbackJournal)
    }

    /// A file replaced under an open connection (a sync client or another
    /// process rewriting it) fails the next write; the database reopens and
    /// the write succeeds instead of surfacing “disk I/O error”.
    func testWriteRecoversAfterDatabaseFileIsReplaced() async throws {
        let url = root.appending(path: ".x-article-archiver/archive.sqlite")
        let database = try ArchiveDatabase(url: url)
        try await database.upsertCreator(Creator(xUserID: "first", username: "first", displayName: "一"))
        try await database.checkpointForDirectorySync()

        let moved = root.appending(path: "moved.sqlite")
        try FileManager.default.moveItem(at: url, to: moved)
        try FileManager.default.copyItem(at: moved, to: url)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }

        var creator = Creator(xUserID: "browser:graceruansu", username: "Graceruansu", displayName: "@Graceruansu")
        creator.knownArticleCount = 42
        try await database.upsertCreator(creator)

        let saved = try await database.creator(xUserID: "browser:graceruansu")
        XCTAssertEqual(saved?.knownArticleCount, 42)
        let reopened = try ArchiveDatabase(url: url)
        let creators = try await reopened.loadCreators()
        XCTAssertEqual(Set(creators.map(\.username)), ["first", "Graceruansu"])
        MarkXLog.flush()
        let log = try String(contentsOf: MarkXLog.currentFileURL, encoding: .utf8)
        XCTAssertTrue(log.contains("重新打开后重试成功"), log)
    }

    func testSyncedNetworkAndFATVolumesUseRollbackJournal() {
        func info(_ path: String, fs: String? = "apfs", local: Bool? = true, ubiquitous: Bool = false) -> StorageLocationInfo {
            StorageLocationInfo(path: path, fileSystem: fs, isLocalVolume: local, isUbiquitous: ubiquitous,
                                isCloudStorageFolder: StorageLocationInfo.isCloudStoragePath(path))
        }
        XCTAssertFalse(info("/Users/a/MarkX").prefersRollbackJournal)
        XCTAssertFalse(info("/Volumes/Mac", fs: "hfs").prefersRollbackJournal)
        XCTAssertTrue(info("/Users/a/Documents/MarkX", ubiquitous: true).prefersRollbackJournal)
        XCTAssertTrue(info("/Users/a/Library/Mobile Documents/com~apple~CloudDocs/MarkX").prefersRollbackJournal)
        XCTAssertTrue(info("/Users/a/Library/CloudStorage/Dropbox/MarkX").prefersRollbackJournal)
        XCTAssertTrue(info("/Volumes/share/MarkX", fs: "smbfs", local: false).prefersRollbackJournal)
        XCTAssertTrue(info("/Volumes/USB/MarkX", fs: "exfat").prefersRollbackJournal)
        XCTAssertTrue(info("/Volumes/USB/MarkX", fs: "msdos").prefersRollbackJournal)
    }

    func testDiskErrorMessageNamesTheCodeAndSuggestsALocalFolder() {
        let message = ArchiveDatabaseError.io(detail: "disk I/O error", code: 5386).localizedDescription
        XCTAssertTrue(message.contains("SQLITE_IOERR_SHMMAP 5386"), message)
        XCTAssertTrue(message.contains("本机磁盘"), message)
        XCTAssertTrue(ArchiveDatabase.isDiskFailure(SQLITE_IOERR))
        XCTAssertTrue(ArchiveDatabase.isDiskFailure(1032))
        XCTAssertFalse(ArchiveDatabase.isDiskFailure(SQLITE_CONSTRAINT))
    }

    func testLogRotatesAndKeepsRecentFiles() throws {
        let line = String(repeating: "x", count: 1024)
        for _ in 0..<(MarkXLog.maximumFileSize / 1024 + 50) {
            MarkXLog.info("test", line)
        }
        MarkXLog.flush()
        XCTAssertGreaterThanOrEqual(MarkXLog.allFileURLs.count, 2)
        let size = try FileManager.default.attributesOfItem(atPath: MarkXLog.currentFileURL.path)[.size] as? Int ?? 0
        XCTAssertLessThan(size, MarkXLog.maximumFileSize)
    }
}
