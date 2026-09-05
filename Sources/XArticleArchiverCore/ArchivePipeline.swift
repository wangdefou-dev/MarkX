import Foundation

public enum ArchivePipelineError: LocalizedError {
    case missingArchiveRoot
    case missingLocalImage(String)
    case missingLocalVideo(String)
    case localFileModified(String)

    public var errorDescription: String? {
        switch self {
        case .missingArchiveRoot: "没有选择本地归档目录"
        case .missingLocalImage(let id): "图片没有本地缓存：\(id)"
        case .missingLocalVideo(let id): "视频没有本地缓存：\(id)"
        case .localFileModified(let path): "本地 Markdown 已被修改，未覆盖：\(path)"
        }
    }
}

public actor ArchivePipeline {
    private let database: ArchiveDatabase
    private let downloader: ImageDownloader
    private let videoDownloader: VideoDownloader
    private let imageHost: any ImageHostAdapter

    public init(
        database: ArchiveDatabase,
        downloader: ImageDownloader = ImageDownloader(),
        videoDownloader: VideoDownloader = VideoDownloader(),
        imageHost: any ImageHostAdapter
    ) {
        self.database = database
        self.downloader = downloader
        self.videoDownloader = videoDownloader
        self.imageHost = imageHost
    }

    public func archive(
        document sourceDocument: CanonicalDocument,
        creator: Creator,
        root: URL,
        progress: (@Sendable (String) async -> Void)? = nil
    ) async throws -> ArchivedArticle {
        let stableKey = sourceDocument.sourceArticleID ?? sourceDocument.sourcePostID
        var document = sourceDocument
        // Fail before any download, upload, database completion state or file
        // write if source text/media cannot be proven internally complete.
        try ContentFidelityValidator.validateCanonical(document)
        let sourceChecksum = try ContentHasher.sourceChecksum(for: sourceDocument)
        let existing = try await database.article(stableSourceKey: stableKey)
        if let existing, existing.sourceChecksum == sourceChecksum, existing.pipelineState == .committed,
           let path = existing.markdownPath, FileManager.default.fileExists(atPath: path) {
            return existing
        }

        var record = ArchivedArticle(
            id: existing?.id ?? UUID(),
            stableSourceKey: stableKey,
            creatorID: creator.id,
            title: document.title,
            authorHandle: document.authorHandle,
            contentType: document.contentType,
            sourceURL: document.sourceURL,
            sourcePostID: document.sourcePostID,
            sourceArticleID: document.sourceArticleID,
            publishedAt: document.publishedAt,
            archivedAt: existing?.archivedAt ?? Date(),
            lastSyncedAt: Date(),
            sourceChecksum: sourceChecksum,
            imageCount: document.media.count,
            videoCount: document.videos?.count ?? 0,
            pipelineState: .parsed,
            warnings: document.warnings
        )
        try await database.upsertArticle(record)

        let internalRoot = root.appending(path: ".x-article-archiver", directoryHint: .isDirectory)
        let cache = internalRoot.appending(path: "assets-cache", directoryHint: .isDirectory)
        let videoCache = internalRoot.appending(path: "video-cache", directoryHint: .isDirectory)
        let pending = internalRoot.appending(path: "pending", directoryHint: .isDirectory)
        let snapshots = internalRoot.appending(path: "source-snapshots", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: videoCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)

        if !document.media.isEmpty {
            await progress?("正在缓存 \(document.media.count) 张原图")
            for index in document.media.indices {
                if let path = document.media[index].localCachePath, FileManager.default.fileExists(atPath: path) { continue }
                document.media[index] = try await downloader.cache(document.media[index], in: cache)
            }
            record.pipelineState = .mediaCached
            try await database.upsertArticle(record)

            await progress?("正在上传 \(document.media.count) 张图片到 \(imageHost.displayName)")
            let pendingMedia = document.media.filter { $0.remoteURL == nil }
            let localURLs = try pendingMedia.map { media -> URL in
                guard let path = media.localCachePath else { throw ArchivePipelineError.missingLocalImage(media.id) }
                return URL(fileURLWithPath: path)
            }
            let uploadResults = try await imageHost.upload(fileURLs: localURLs)
            let remoteByPath = Dictionary(uniqueKeysWithValues: uploadResults.map { ($0.localPath, $0.remoteURL) })
            for index in document.media.indices where document.media[index].remoteURL == nil {
                guard let path = document.media[index].localCachePath, let remoteURL = remoteByPath[path] else {
                    throw ImagePipelineError.outputCountMismatch(expected: localURLs.count, actual: remoteByPath.count)
                }
                try await imageHost.verify(remoteURL: remoteURL)
                document.media[index].remoteURL = remoteURL
            }
            record.pipelineState = .mediaUploaded
            try await database.upsertArticle(record)
        }

        if var videos = document.videos, !videos.isEmpty {
            await progress?("正在下载 \(videos.count) 个视频原文件")
            for index in videos.indices {
                if let path = videos[index].localCachePath,
                   FileManager.default.fileExists(atPath: path) { continue }
                videos[index] = try await videoDownloader.cache(videos[index], in: videoCache)
            }
            document.videos = videos
            record.pipelineState = .mediaCached
            try await database.upsertArticle(record)

            await progress?("正在上传 \(videos.count) 个视频到 \(imageHost.displayName)")
            let pendingVideos = videos.filter { $0.remoteURL == nil }
            let localURLs = try pendingVideos.map { video -> URL in
                guard let path = video.localCachePath else {
                    throw ArchivePipelineError.missingLocalVideo(video.id)
                }
                return URL(fileURLWithPath: path)
            }
            let uploadResults = try await imageHost.upload(fileURLs: localURLs)
            let remoteByPath = Dictionary(uniqueKeysWithValues: uploadResults.map { ($0.localPath, $0.remoteURL) })
            for index in videos.indices where videos[index].remoteURL == nil {
                guard let path = videos[index].localCachePath,
                      let remoteURL = remoteByPath[path] else {
                    throw ImagePipelineError.outputCountMismatch(
                        expected: localURLs.count,
                        actual: remoteByPath.count
                    )
                }
                try await imageHost.verifyVideo(remoteURL: remoteURL)
                videos[index].remoteURL = remoteURL
            }
            document.videos = videos
            record.pipelineState = .mediaUploaded
            try await database.upsertArticle(record)
        }

        await progress?("正在生成并校验 Markdown")
        let markdown = try MarkdownRenderer.render(document: document)
        try MarkdownRenderer.validateRenderedText(document: document, markdown: markdown)
        record.pipelineState = .verified
        try await database.upsertArticle(record)

        let creatorDirectory = root.appending(path: SafeFileName.creatorDirectory(handle: creator.username, displayName: creator.displayName), directoryHint: .isDirectory)
        let articlesDirectory = creatorDirectory.appending(path: "articles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: articlesDirectory, withIntermediateDirectories: true)
        let fileName = SafeFileName.articleFileName(title: document.title, publishedAt: document.publishedAt, postID: document.sourcePostID)
        let destination = articlesDirectory.appending(path: fileName)

        var obsoleteCleanFile: URL?
        if let existing, let oldPath = existing.markdownPath, FileManager.default.fileExists(atPath: oldPath) {
            let oldContents = try String(contentsOfFile: oldPath, encoding: .utf8)
            if !MarkdownRenderer.isUnmodifiedExport(oldContents) {
                let incoming = destination.deletingPathExtension().appendingPathExtension("incoming.md")
                try Data(markdown.utf8).write(to: incoming, options: .atomic)
                throw ArchivePipelineError.localFileModified(destination.path)
            }
            if oldPath != destination.path {
                obsoleteCleanFile = URL(fileURLWithPath: oldPath)
            }
        }

        let finalMarkdown = MarkdownRenderer.addingExportChecksum(to: markdown)
        let staging = pending.appending(path: "\(stableKey)-\(UUID().uuidString).md")
        try Data(finalMarkdown.utf8).write(to: staging, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        if let obsoleteCleanFile, FileManager.default.fileExists(atPath: obsoleteCleanFile.path) {
            try FileManager.default.removeItem(at: obsoleteCleanFile)
        }

        let snapshotEncoder = JSONEncoder()
        snapshotEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        snapshotEncoder.dateEncodingStrategy = .iso8601
        try snapshotEncoder.encode(document).write(to: snapshots.appending(path: "\(stableKey).json"), options: .atomic)

        record.markdownPath = destination.path
        record.pipelineState = .committed
        record.lastSyncedAt = Date()
        record.warnings = document.warnings
        try await database.upsertArticle(record)
        try ArchiveIndexWriter.rebuild(root: root, creator: creator)
        await progress?("已完成：\(document.title)")
        return record
    }

}

public enum ArchiveIndexWriter {
    public static func rebuild(root: URL, creator: Creator) throws {
        let creatorDirectory = root.appending(path: SafeFileName.creatorDirectory(handle: creator.username, displayName: creator.displayName), directoryHint: .isDirectory)
        let articlesDirectory = creatorDirectory.appending(path: "articles", directoryHint: .isDirectory)
        // A pending Article may be deleted before its first Markdown exists.
        // Rebuilding an empty creator index must still succeed so no ghost row
        // remains visible after the database deletion.
        try FileManager.default.createDirectory(at: articlesDirectory, withIntermediateDirectories: true)
        let creatorIndex = creatorDirectory.appending(path: "index.md")
        let articles = try FileManager.default.contentsOfDirectory(at: articlesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines = ["# @\(creator.username) · \(creator.displayName)", "", "共 \(articles.count) 篇本地长文。", ""]
        for url in articles {
            lines.append("- [\(url.deletingPathExtension().lastPathComponent)](articles/\(url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.lastPathComponent))")
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: creatorIndex, options: .atomic)

        let rootIndex = root.appending(path: "index.md")
        var rootLines = ["# X 长文归档", "", "最后更新：\(Date().formatted(date: .numeric, time: .standard))", ""]
        let creatorDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.hasPrefix("@") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for directory in creatorDirectories {
            let encoded = directory.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? directory.lastPathComponent
            rootLines.append("- [\(directory.lastPathComponent)](\(encoded)/index.md)")
        }
        try Data((rootLines.joined(separator: "\n") + "\n").utf8).write(to: rootIndex, options: .atomic)
    }
}
