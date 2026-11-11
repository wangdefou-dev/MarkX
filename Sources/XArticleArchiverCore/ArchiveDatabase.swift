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
    private let iso8601Formatter = ISO8601DateFormatter()

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
          (id, x_user_id, username, display_name, profile_image_url, is_protected, is_enabled, last_sync_at, last_seen_post_id, completeness, known_article_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(x_user_id) DO UPDATE SET
          username=excluded.username,
          display_name=excluded.display_name,
          profile_image_url=excluded.profile_image_url,
          is_protected=excluded.is_protected,
          is_enabled=excluded.is_enabled,
          last_sync_at=excluded.last_sync_at,
          last_seen_post_id=excluded.last_seen_post_id,
          completeness=excluded.completeness,
          known_article_count=COALESCE(excluded.known_article_count, creators.known_article_count);
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
        bind(creator.lastSyncAt.map(iso8601), to: 8, in: statement)
        bind(creator.lastSeenPostID, to: 9, in: statement)
        bind(creator.completeness.rawValue, to: 10, in: statement)
        bind(creator.knownArticleCount, to: 11, in: statement)
        try step(statement)
    }

    public func loadCreators() throws -> [Creator] {
        let statement = try prepare("SELECT id, x_user_id, username, display_name, profile_image_url, is_protected, is_enabled, last_sync_at, last_seen_post_id, completeness, known_article_count FROM creators ORDER BY username COLLATE NOCASE;")
        defer { sqlite3_finalize(statement) }
        var output: [Creator] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let creator = creator(from: statement) {
                output.append(creator)
            }
        }
        return output
    }

    public func creator(xUserID: String) throws -> Creator? {
        let statement = try prepare("SELECT id, x_user_id, username, display_name, profile_image_url, is_protected, is_enabled, last_sync_at, last_seen_post_id, completeness, known_article_count FROM creators WHERE x_user_id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(xUserID, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return creator(from: statement)
    }

    public func creator(username: String) throws -> Creator? {
        let statement = try prepare("SELECT id, x_user_id, username, display_name, profile_image_url, is_protected, is_enabled, last_sync_at, last_seen_post_id, completeness, known_article_count FROM creators WHERE username = ? COLLATE NOCASE LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bind(username, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return creator(from: statement)
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
          last_seen_post_id = ?, completeness = ?, known_article_count = ?
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
        bind(creator.lastSyncAt.map(iso8601), to: 7, in: statement)
        bind(creator.lastSeenPostID, to: 8, in: statement)
        bind(creator.completeness.rawValue, to: 9, in: statement)
        bind(creator.knownArticleCount, to: 10, in: statement)
        bind(creator.id.uuidString, to: 11, in: statement)
        try step(statement)
    }

    public func upsertArticle(_ article: ArchivedArticle) throws {
        let warningsData = try JSONEncoder().encode(article.warnings)
        let warnings = String(data: warningsData, encoding: .utf8) ?? "[]"
        let processingLogData = try JSONEncoder().encode(article.processingLog)
        let processingLog = String(data: processingLogData, encoding: .utf8) ?? "[]"
        let sql = """
        INSERT INTO articles
          (id, stable_source_key, creator_id, title, author_handle, content_type, source_url, source_post_id, source_article_id,
           published_at, archived_at, last_synced_at, source_status, source_checksum, markdown_path, image_count, video_count, pipeline_state, warnings, last_error, processing_log, is_paid_partnership, paid_partnership_checked)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
          video_count=excluded.video_count,
          pipeline_state=excluded.pipeline_state,
          warnings=excluded.warnings,
          last_error=excluded.last_error,
          processing_log=excluded.processing_log,
          is_paid_partnership=excluded.is_paid_partnership,
          paid_partnership_checked=excluded.paid_partnership_checked;
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
        bind(iso8601(article.publishedAt), to: 10, in: statement)
        bind(iso8601(article.archivedAt), to: 11, in: statement)
        bind(iso8601(article.lastSyncedAt), to: 12, in: statement)
        bind(article.sourceStatus.rawValue, to: 13, in: statement)
        bind(article.sourceChecksum, to: 14, in: statement)
        bind(article.markdownPath, to: 15, in: statement)
        sqlite3_bind_int(statement, 16, Int32(article.imageCount))
        sqlite3_bind_int(statement, 17, Int32(article.videoCount))
        bind(article.pipelineState.rawValue, to: 18, in: statement)
        bind(warnings, to: 19, in: statement)
        bind(article.lastError, to: 20, in: statement)
        bind(processingLog, to: 21, in: statement)
        sqlite3_bind_int(statement, 22, article.isPaidPartnership ? 1 : 0)
        sqlite3_bind_int(statement, 23, article.paidPartnershipChecked ? 1 : 0)
        try step(statement)
    }

    public func loadArticles() throws -> [ArchivedArticle] {
        try loadArticles(
            sql: "SELECT \(Self.articleSelectColumns) FROM articles ORDER BY published_at DESC;",
            includeProcessingLog: true
        )
    }

    /// Fast path for the library window: only X Articles, newest first, and no
    /// processing-log JSON. Opening 10,000 rows must not decode a log per row.
    public func loadLibraryArticles() throws -> [ArchivedArticle] {
        try loadArticles(
            sql: """
            SELECT \(Self.articleSelectColumns) FROM articles
            WHERE content_type = 'x_article'
            ORDER BY published_at DESC;
            """,
            includeProcessingLog: false
        )
    }

    public func indexedArticleIDs() throws -> Set<UUID> {
        let statement = try prepare("SELECT article_id FROM article_search_v2;")
        defer { sqlite3_finalize(statement) }
        var ids = Set<UUID>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = text(statement, 0), let id = UUID(uuidString: raw) { ids.insert(id) }
        }
        return ids
    }

    public func indexArticle(_ article: ArchivedArticle, body: String) throws {
        let delete = try prepare("DELETE FROM article_search_v2 WHERE article_id = ?;")
        defer { sqlite3_finalize(delete) }
        bind(article.id.uuidString, to: 1, in: delete)
        try step(delete)
        let insert = try prepare("INSERT INTO article_search_v2(article_id, title, author_handle, body) VALUES (?, ?, ?, ?);")
        defer { sqlite3_finalize(insert) }
        bind(article.id.uuidString, to: 1, in: insert)
        bind(article.title, to: 2, in: insert)
        bind(article.authorHandle, to: 3, in: insert)
        bind(body, to: 4, in: insert)
        try step(insert)
    }

    public func commitArticle(_ article: ArchivedArticle, searchBody: String) throws {
        try Self.execute(on: database, sql: "BEGIN IMMEDIATE;")
        do {
            try upsertArticle(article)
            try indexArticle(article, body: searchBody)
            try Self.execute(on: database, sql: "COMMIT;")
        } catch {
            try? Self.execute(on: database, sql: "ROLLBACK;")
            throw error
        }
    }

    public func searchArticleIDs(_ input: String) throws -> Set<UUID> {
        let query = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        guard !query.isEmpty else { return [] }
        // Trigrams support Chinese substring search. One/two-character input
        // uses literal LIKE because it cannot form a trigram.
        let sql: String
        let value: String
        if query.count >= 3 {
            sql = "SELECT article_id FROM article_search_v2 WHERE article_search_v2 MATCH ?;"
            value = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        } else {
            sql = "SELECT article_id FROM article_search_v2 WHERE title LIKE ? ESCAPE '\\' OR author_handle LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\';"
            value = "%" + query.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(value, to: 1, in: statement)
        if query.count < 3 { bind(value, to: 2, in: statement); bind(value, to: 3, in: statement) }
        var ids = Set<UUID>()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let raw = text(statement, 0), let id = UUID(uuidString: raw) { ids.insert(id) }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw ArchiveDatabaseError.execute(String(cString: sqlite3_errmsg(database))) }
        return ids
    }

    private func loadArticles(sql: String, includeProcessingLog: Bool) throws -> [ArchivedArticle] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var output: [ArchivedArticle] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let article = article(from: statement, includeProcessingLog: includeProcessingLog) {
                output.append(article)
            }
        }
        return output
    }

    /// Pending capture rows only. Bulk jobs persist the rest of the queue here
    /// so RAM never holds tens of thousands of WKWebView tasks at once.
    public func loadArticlesNeedingCapture(
        limit: Int,
        excludingPostIDs: Set<String> = []
    ) throws -> [ArchivedArticle] {
        let sql = """
        SELECT \(Self.articleSelectColumns) FROM articles
        WHERE pipeline_state NOT IN ('committed', 'subscription_required')
        ORDER BY CASE pipeline_state
            WHEN 'discovered' THEN 0
            WHEN 'parsed' THEN 1
            ELSE 2
        END,
        published_at DESC
        LIMIT ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(limit + excludingPostIDs.count, limit)))
        var output: [ArchivedArticle] = []
        while sqlite3_step(statement) == SQLITE_ROW, output.count < limit {
            guard let article = article(from: statement),
                  !excludingPostIDs.contains(article.sourcePostID),
                  ExactCaptureQueuePolicy.needsCapture(article) else { continue }
            output.append(article)
        }
        return output
    }

    public func countArticlesNeedingCapture() throws -> Int {
        let sql = """
        SELECT COUNT(*) FROM articles
        WHERE pipeline_state NOT IN ('committed', 'subscription_required');
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func article(stableSourceKey: String) throws -> ArchivedArticle? {
        try article(matching: "stable_source_key", value: stableSourceKey)
    }

    public func article(sourcePostID: String) throws -> ArchivedArticle? {
        try article(matching: "source_post_id", value: sourcePostID)
    }

    private func article(matching column: String, value: String) throws -> ArchivedArticle? {
        let sql = "SELECT \(Self.articleSelectColumns) FROM articles WHERE \(column) = ? LIMIT 1;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(value, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return article(from: statement, includeProcessingLog: true)
    }

    private func article(from statement: OpaquePointer?, includeProcessingLog: Bool = true) -> ArchivedArticle? {
        guard let id = UUID(uuidString: text(statement, 0) ?? ""),
              let creatorID = UUID(uuidString: text(statement, 2) ?? ""),
              let stableKey = text(statement, 1),
              let title = text(statement, 3),
              let handle = text(statement, 4),
              let type = LongformContentType(rawValue: text(statement, 5) ?? ""),
              let sourceURLString = text(statement, 6),
              let sourceURL = URL(string: sourceURLString),
              let postID = text(statement, 7),
              let publishedAt = text(statement, 9).flatMap(parseDate),
              let archivedAt = text(statement, 10).flatMap(parseDate),
              let lastSyncedAt = text(statement, 11).flatMap(parseDate),
              let sourceStatus = SourceStatus(rawValue: text(statement, 12) ?? ""),
              let checksum = text(statement, 13),
              let pipeline = PipelineState(rawValue: text(statement, 17) ?? "") else { return nil }
        let warningData = Data((text(statement, 18) ?? "[]").utf8)
        let warnings = (try? JSONDecoder().decode([String].self, from: warningData)) ?? []
        let processingLog: [String]
        if includeProcessingLog {
            let processingLogData = Data((text(statement, 20) ?? "[]").utf8)
            processingLog = (try? JSONDecoder().decode([String].self, from: processingLogData)) ?? []
        } else {
            processingLog = []
        }
        return ArchivedArticle(
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
            videoCount: Int(sqlite3_column_int(statement, 16)),
            pipelineState: pipeline,
            warnings: warnings,
            lastError: text(statement, 19),
            processingLog: processingLog,
            isPaidPartnership: sqlite3_column_int(statement, 21) != 0,
            paidPartnershipChecked: sqlite3_column_int(statement, 22) != 0
        )
    }

    private func creator(from statement: OpaquePointer?) -> Creator? {
        guard let id = UUID(uuidString: text(statement, 0) ?? ""),
              let xUserID = text(statement, 1),
              let username = text(statement, 2),
              let displayName = text(statement, 3) else { return nil }
        return Creator(
            id: id,
            xUserID: xUserID,
            username: username,
            displayName: displayName,
            profileImageURL: text(statement, 4).flatMap(URL.init(string:)),
            isProtected: sqlite3_column_int(statement, 5) != 0,
            isEnabled: sqlite3_column_int(statement, 6) != 0,
            lastSyncAt: text(statement, 7).flatMap(parseDate),
            lastSeenPostID: text(statement, 8),
            completeness: CompletenessStatus(rawValue: text(statement, 9) ?? "") ?? .unknown,
            knownArticleCount: optionalInt(statement, 10)
        )
    }

    public func loadCollections() throws -> [ArticleCollection] {
        let statement = try prepare("""
        SELECT collections.id, collections.name, collection_articles.article_id
        FROM collections LEFT JOIN collection_articles ON collections.id = collection_articles.collection_id
        ORDER BY collections.name COLLATE NOCASE, collections.id;
        """)
        defer { sqlite3_finalize(statement) }
        var collections: [ArticleCollection] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let id = text(statement, 0).flatMap(UUID.init(uuidString:)),
                  let name = text(statement, 1) else {
                throw ArchiveDatabaseError.execute("收藏夹记录无法读取")
            }
            if collections.last?.id != id {
                collections.append(ArticleCollection(id: id, name: name, articleIDs: []))
            }
            if let articleID = text(statement, 2).flatMap(UUID.init(uuidString:)) {
                collections[collections.count - 1].articleIDs.insert(articleID)
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw ArchiveDatabaseError.execute(String(cString: sqlite3_errmsg(database)))
        }
        return collections
    }

    public func createCollection(name: String, articleID: UUID? = nil) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\0") else { throw ArticleCollectionError.invalidName }
        let id = UUID()
        try Self.execute(on: database, sql: "BEGIN IMMEDIATE;")
        do {
            let statement = try prepare("INSERT INTO collections (id, name) VALUES (?, ?) ON CONFLICT(name) DO NOTHING;")
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, to: 1, in: statement)
            bind(name, to: 2, in: statement)
            try step(statement)
            guard sqlite3_changes(database) == 1 else { throw ArticleCollectionError.duplicateName }
            if let articleID {
                try setArticle(articleID, inCollection: id, included: true)
            }
            try Self.execute(on: database, sql: "COMMIT;")
        } catch {
            try? Self.execute(on: database, sql: "ROLLBACK;")
            throw error
        }
    }

    public func setArticle(_ articleID: UUID, inCollection collectionID: UUID, included: Bool) throws {
        let sql = included
            ? "INSERT INTO collection_articles (collection_id, article_id) VALUES (?, ?) ON CONFLICT(collection_id, article_id) DO NOTHING;"
            : "DELETE FROM collection_articles WHERE collection_id = ? AND article_id = ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(collectionID.uuidString, to: 1, in: statement)
        bind(articleID.uuidString, to: 2, in: statement)
        try step(statement)
    }

    public func deleteCollection(id: UUID) throws {
        let statement = try prepare("DELETE FROM collections WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try step(statement)
    }

    public func deleteArticle(id: UUID) throws {
        let search = try prepare("DELETE FROM article_search_v2 WHERE article_id = ?;")
        defer { sqlite3_finalize(search) }
        bind(id.uuidString, to: 1, in: search)
        try step(search)
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
          completeness TEXT NOT NULL DEFAULT 'UNKNOWN',
          known_article_count INTEGER
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
          video_count INTEGER NOT NULL DEFAULT 0,
          pipeline_state TEXT NOT NULL,
          warnings TEXT NOT NULL DEFAULT '[]',
          last_error TEXT,
          processing_log TEXT NOT NULL DEFAULT '[]',
          is_paid_partnership INTEGER NOT NULL DEFAULT 0,
          paid_partnership_checked INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY (creator_id) REFERENCES creators(id)
        );
        CREATE INDEX IF NOT EXISTS idx_articles_published_at ON articles(published_at DESC);
        CREATE INDEX IF NOT EXISTS idx_articles_creator_id ON articles(creator_id);
        CREATE INDEX IF NOT EXISTS idx_articles_source_post_id ON articles(source_post_id);
        CREATE INDEX IF NOT EXISTS idx_articles_content_type_published ON articles(content_type, published_at DESC);
        CREATE INDEX IF NOT EXISTS idx_creators_username ON creators(username COLLATE NOCASE);
        CREATE VIRTUAL TABLE IF NOT EXISTS article_search USING fts5(title, author_handle, body, content='');
        CREATE VIRTUAL TABLE IF NOT EXISTS article_search_v2 USING fts5(article_id UNINDEXED, title, author_handle, body, tokenize='trigram');
        CREATE TABLE IF NOT EXISTS collections (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL COLLATE NOCASE UNIQUE
        );
        CREATE TABLE IF NOT EXISTS collection_articles (
          collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
          article_id TEXT NOT NULL REFERENCES articles(id) ON DELETE CASCADE,
          PRIMARY KEY (collection_id, article_id)
        );
        CREATE INDEX IF NOT EXISTS idx_collection_articles_article ON collection_articles(article_id);
        """)
        if !columnExists(on: database, table: "articles", column: "video_count") {
            try execute(on: database, sql: "ALTER TABLE articles ADD COLUMN video_count INTEGER NOT NULL DEFAULT 0;")
        }
        if !columnExists(on: database, table: "articles", column: "processing_log") {
            try execute(on: database, sql: "ALTER TABLE articles ADD COLUMN processing_log TEXT NOT NULL DEFAULT '[]';")
        }
        if !columnExists(on: database, table: "creators", column: "known_article_count") {
            try execute(on: database, sql: "ALTER TABLE creators ADD COLUMN known_article_count INTEGER;")
        }
        if !columnExists(on: database, table: "articles", column: "is_paid_partnership") {
            try execute(on: database, sql: "ALTER TABLE articles ADD COLUMN is_paid_partnership INTEGER NOT NULL DEFAULT 0;")
        }
        if !columnExists(on: database, table: "articles", column: "paid_partnership_checked") {
            try execute(on: database, sql: "ALTER TABLE articles ADD COLUMN paid_partnership_checked INTEGER NOT NULL DEFAULT 0;")
        }
        try execute(on: database, sql: "PRAGMA user_version=8;")
    }

    private static let articleSelectColumns = "id, stable_source_key, creator_id, title, author_handle, content_type, source_url, source_post_id, source_article_id, published_at, archived_at, last_synced_at, source_status, source_checksum, markdown_path, image_count, video_count, pipeline_state, warnings, last_error, processing_log, is_paid_partnership, paid_partnership_checked"

    private static func columnExists(on database: OpaquePointer?, table: String, column: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: value) == column { return true }
        }
        return false
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

    private func bind(_ value: Int?, to index: Int32, in statement: OpaquePointer?) {
        if let value { sqlite3_bind_int64(statement, index, Int64(value)) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func optionalInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
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

    private func iso8601(_ date: Date) -> String { iso8601Formatter.string(from: date) }
    private func parseDate(_ value: String) -> Date? { iso8601Formatter.date(from: value) }
}
