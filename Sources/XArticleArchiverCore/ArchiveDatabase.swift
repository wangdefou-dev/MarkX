import Foundation
import SQLite3

public enum ArchiveDatabaseError: LocalizedError {
    case open(String)
    case execute(String)
    case prepare(String)

    public var errorDescription: String? {
        switch self {
        case .open(let detail): "无法打开归档数据库：\(detail)"
        case .execute(let detail): "数据库执行失败：\(detail)"
        case .prepare(let detail): "数据库语句准备失败：\(detail)"
        }
    }
}

public actor ArchiveDatabase {
    nonisolated(unsafe) private var database: OpaquePointer?
    public let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let detail = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let pointer { sqlite3_close(pointer) }
            throw ArchiveDatabaseError.open(detail)
        }
        database = pointer
        try Self.execute(on: pointer, sql: "PRAGMA journal_mode=WAL;")
        try Self.execute(on: pointer, sql: "PRAGMA foreign_keys=ON;")
        try Self.migrate(on: pointer)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    public func upsertCreator(_ creator: Creator) throws {
        let sql = """
        INSERT INTO creators
          (id, x_user_id, username, display_name, profile_image_url, is_protected, is_enabled, last_sync_at, last_seen_post_id, completeness)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(x_user_id) DO UPDATE SET
          username=excluded.username,
          display_name=excluded.display_name,
          profile_image_url=excluded.profile_image_url,
          is_protected=excluded.is_protected,
          is_enabled=excluded.is_enabled,
          last_sync_at=excluded.last_sync_at,
          last_seen_post_id=excluded.last_seen_post_id,
          completeness=excluded.completeness;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(creator.id.uuidString, to: 1, in: statement)
        bind(creator.xUserID, to: 2, in: statement)
        bind(creator.username, to: 3, in: statement)
        bind(creator.displayName, to: 4, in: statement)
        bind(creator.profileImageURL?.absoluteString, to: 5, in: statement)
        sqlite3_bind_int(statement, 6, creator.isProtected ? 1 : 0)
        sqlite3_bind_int(statement, 7, creator.isEnabled ? 1 : 0)
        bind(creator.lastSyncAt.map(Self.iso8601), to: 8, in: statement)
        bind(creator.lastSeenPostID, to: 9, in: statement)
        bind(creator.completeness.rawValue, to: 10, in: statement)
        try step(statement)
    }

    public func loadCreators() throws -> [Creator] {
        let statement = try prepare("SELECT id, x_user_id, username, display_name, profile_image_url, is_protected, is_enabled, last_sync_at, last_seen_post_id, completeness FROM creators ORDER BY username COLLATE NOCASE;")
        defer { sqlite3_finalize(statement) }
        var output: [Creator] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0) ?? ""),
                  let xUserID = text(statement, 1),
                  let username = text(statement, 2),
                  let displayName = text(statement, 3) else { continue }
            output.append(Creator(
                id: id,
                xUserID: xUserID,
                username: username,
                displayName: displayName,
                profileImageURL: text(statement, 4).flatMap(URL.init(string:)),
                isProtected: sqlite3_column_int(statement, 5) != 0,
                isEnabled: sqlite3_column_int(statement, 6) != 0,
                lastSyncAt: text(statement, 7).flatMap(Self.parseDate),
                lastSeenPostID: text(statement, 8),
                completeness: CompletenessStatus(rawValue: text(statement, 9) ?? "") ?? .unknown
            ))
        }
        return output
    }

    public func creator(xUserID: String) throws -> Creator? {
        try loadCreators().first { $0.xUserID == xUserID }
    }

    public func creator(username: String) throws -> Creator? {
        try loadCreators().first { $0.username.caseInsensitiveCompare(username) == .orderedSame }
    }

    /// Soft-removes a creator from the tracking list. Existing article rows
    /// keep their foreign-key owner and downloaded files remain untouched.
    public func setCreatorEnabled(id: UUID, isEnabled: Bool) throws {
        let statement = try prepare("UPDATE creators SET is_enabled = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, isEnabled ? 1 : 0)
        bind(id.uuidString, to: 2, in: statement)
        try step(statement)
    }

    /// Replaces the temporary `browser:<handle>` identity after the user later
    /// enables official API discovery for that creator. The row UUID remains
    /// stable, so previously captured articles keep their owner relationship.
    public func updateCreatorIdentity(_ creator: Creator) throws {
        let sql = """
        UPDATE creators SET
          x_user_id = ?, username = ?, display_name = ?, profile_image_url = ?,
          is_protected = ?, is_enabled = ?, last_sync_at = ?,
          last_seen_post_id = ?, completeness = ?
        WHERE id = ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(creator.xUserID, to: 1, in: statement)
        bind(creator.username, to: 2, in: statement)
        bind(creator.displayName, to: 3, in: statement)
        bind(creator.profileImageURL?.absoluteString, to: 4, in: statement)
        sqlite3_bind_int(statement, 5, creator.isProtected ? 1 : 0)
        sqlite3_bind_int(statement, 6, creator.isEnabled ? 1 : 0)
        bind(creator.lastSyncAt.map(Self.iso8601), to: 7, in: statement)
        bind(creator.lastSeenPostID, to: 8, in: statement)
        bind(creator.completeness.rawValue, to: 9, in: statement)
        bind(creator.id.uuidString, to: 10, in: statement)
        try step(statement)
    }

    public func upsertArticle(_ article: ArchivedArticle) throws {
        let warningsData = try JSONEncoder().encode(article.warnings)
        let warnings = String(data: warningsData, encoding: .utf8) ?? "[]"
        let sql = """
        INSERT INTO articles
          (id, stable_source_key, creator_id, title, author_handle, content_type, source_url, source_post_id, source_article_id,
           published_at, archived_at, last_synced_at, source_status, source_checksum, markdown_path, image_count, pipeline_state, warnings, last_error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(stable_source_key) DO UPDATE SET
          creator_id=excluded.creator_id,
          title=excluded.title,
          author_handle=excluded.author_handle,
          content_type=excluded.content_type,
          source_url=excluded.source_url,
          source_post_id=excluded.source_post_id,
          source_article_id=excluded.source_article_id,
          published_at=excluded.published_at,
          last_synced_at=excluded.last_synced_at,
          source_status=excluded.source_status,
          source_checksum=excluded.source_checksum,
          markdown_path=excluded.markdown_path,
          image_count=excluded.image_count,
          pipeline_state=excluded.pipeline_state,
          warnings=excluded.warnings,
          last_error=excluded.last_error;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(article.id.uuidString, to: 1, in: statement)
        bind(article.stableSourceKey, to: 2, in: statement)
        bind(article.creatorID.uuidString, to: 3, in: statement)
        bind(article.title, to: 4, in: statement)
        bind(article.authorHandle, to: 5, in: statement)
        bind(article.contentType.rawValue, to: 6, in: statement)
        bind(article.sourceURL.absoluteString, to: 7, in: statement)
        bind(article.sourcePostID, to: 8, in: statement)
        bind(article.sourceArticleID, to: 9, in: statement)
        bind(Self.iso8601(article.publishedAt), to: 10, in: statement)
        bind(Self.iso8601(article.archivedAt), to: 11, in: statement)
        bind(Self.iso8601(article.lastSyncedAt), to: 12, in: statement)
        bind(article.sourceStatus.rawValue, to: 13, in: statement)
        bind(article.sourceChecksum, to: 14, in: statement)
        bind(article.markdownPath, to: 15, in: statement)
        sqlite3_bind_int(statement, 16, Int32(article.imageCount))
        bind(article.pipelineState.rawValue, to: 17, in: statement)
        bind(warnings, to: 18, in: statement)
        bind(article.lastError, to: 19, in: statement)
        try step(statement)
    }

    public func loadArticles() throws -> [ArchivedArticle] {
        let sql = "SELECT id, stable_source_key, creator_id, title, author_handle, content_type, source_url, source_post_id, source_article_id, published_at, archived_at, last_synced_at, source_status, source_checksum, markdown_path, image_count, pipeline_state, warnings, last_error FROM articles ORDER BY published_at DESC;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var output: [ArchivedArticle] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0) ?? ""),
                  let creatorID = UUID(uuidString: text(statement, 2) ?? ""),
                  let stableKey = text(statement, 1),
                  let title = text(statement, 3),
                  let handle = text(statement, 4),
                  let type = LongformContentType(rawValue: text(statement, 5) ?? ""),
                  let sourceURLString = text(statement, 6),
                  let sourceURL = URL(string: sourceURLString),
                  let postID = text(statement, 7),
                  let publishedAt = text(statement, 9).flatMap(Self.parseDate),
                  let archivedAt = text(statement, 10).flatMap(Self.parseDate),
                  let lastSyncedAt = text(statement, 11).flatMap(Self.parseDate),
                  let sourceStatus = SourceStatus(rawValue: text(statement, 12) ?? ""),
                  let checksum = text(statement, 13),
                  let pipeline = PipelineState(rawValue: text(statement, 16) ?? "") else { continue }
            let warningData = Data((text(statement, 17) ?? "[]").utf8)
            let warnings = (try? JSONDecoder().decode([String].self, from: warningData)) ?? []
            output.append(ArchivedArticle(
                id: id,
                stableSourceKey: stableKey,
                creatorID: creatorID,
                title: title,
                authorHandle: handle,
                contentType: type,
                sourceURL: sourceURL,
                sourcePostID: postID,
                sourceArticleID: text(statement, 8),
                publishedAt: publishedAt,
                archivedAt: archivedAt,
                lastSyncedAt: lastSyncedAt,
                sourceStatus: sourceStatus,
                sourceChecksum: checksum,
                markdownPath: text(statement, 14),
                imageCount: Int(sqlite3_column_int(statement, 15)),
                pipelineState: pipeline,
                warnings: warnings,
                lastError: text(statement, 18)
            ))
        }
        return output
    }

    public func article(stableSourceKey: String) throws -> ArchivedArticle? {
        try loadArticles().first(where: { $0.stableSourceKey == stableSourceKey })
    }

    public func article(sourcePostID: String) throws -> ArchivedArticle? {
        try loadArticles().first(where: { $0.sourcePostID == sourcePostID })
    }

    public func deleteArticle(id: UUID) throws {
        let statement = try prepare("DELETE FROM articles WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try step(statement)
    }

    /// Flushes committed WAL pages into the main database file so a directory
    /// copy can move one self-contained SQLite database safely.
    public func checkpointForDirectorySync() throws {
        try Self.execute(on: database, sql: "PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Used only for a destination database inspected during a retry. Closing
    /// explicitly makes it safe to remove its now-empty WAL/SHM sidecars before
    /// atomically replacing the main database file.
    public func closeAfterCheckpointForDirectorySync() throws {
        try checkpointForDirectorySync()
        guard let database else { return }
        let result = sqlite3_close(database)
        guard result == SQLITE_OK else {
            throw ArchiveDatabaseError.execute(String(cString: sqlite3_errstr(result)))
        }
        self.database = nil
    }

    private static func migrate(on database: OpaquePointer?) throws {
        try execute(on: database, sql: """
        CREATE TABLE IF NOT EXISTS creators (
          id TEXT PRIMARY KEY,
          x_user_id TEXT NOT NULL UNIQUE,
          username TEXT NOT NULL,
          display_name TEXT NOT NULL,
          profile_image_url TEXT,
          is_protected INTEGER NOT NULL DEFAULT 0,
          is_enabled INTEGER NOT NULL DEFAULT 1,
          last_sync_at TEXT,
          last_seen_post_id TEXT,
          completeness TEXT NOT NULL DEFAULT 'UNKNOWN'
        );
        CREATE TABLE IF NOT EXISTS articles (
          id TEXT PRIMARY KEY,
          stable_source_key TEXT NOT NULL UNIQUE,
          creator_id TEXT NOT NULL,
          title TEXT NOT NULL,
          author_handle TEXT NOT NULL,
          content_type TEXT NOT NULL,
          source_url TEXT NOT NULL,
          source_post_id TEXT NOT NULL,
          source_article_id TEXT,
          published_at TEXT NOT NULL,
          archived_at TEXT NOT NULL,
          last_synced_at TEXT NOT NULL,
          source_status TEXT NOT NULL,
          source_checksum TEXT NOT NULL,
          markdown_path TEXT,
          image_count INTEGER NOT NULL DEFAULT 0,
          pipeline_state TEXT NOT NULL,
          warnings TEXT NOT NULL DEFAULT '[]',
          last_error TEXT,
          FOREIGN KEY (creator_id) REFERENCES creators(id)
        );
        CREATE INDEX IF NOT EXISTS idx_articles_published_at ON articles(published_at DESC);
        CREATE INDEX IF NOT EXISTS idx_articles_creator_id ON articles(creator_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS article_search USING fts5(title, author_handle, body, content='');
        PRAGMA user_version=1;
        """)
    }

    private static func execute(on database: OpaquePointer?, sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(error)
            throw ArchiveDatabaseError.execute(detail)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ArchiveDatabaseError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer?) {
        if let value { sqlite3_bind_text(statement, index, value, -1, transient) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ArchiveDatabaseError.execute(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func parseDate(_ value: String) -> Date? { ISO8601DateFormatter().date(from: value) }
}
