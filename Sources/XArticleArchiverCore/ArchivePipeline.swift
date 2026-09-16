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
            let isPaid = sourceDocument.isPaidPartnership == true
            if existing.isPaidPartnership != isPaid || !existing.paidPartnershipChecked {
                var updated = existing
                updated.isPaidPartnership = isPaid
                updated.paidPartnershipChecked = true
                updated.lastSyncedAt = Date()
                if isPaid != existing.isPaidPartnership {
                    updated.appendProcessingLog(
                        isPaid
                            ? "已识别 X 官方付费合作（Paid partnership）标记"
                            : "已核对：不是商单内容"
                    )
                }
                if let path = existing.markdownPath,
                   FileManager.default.fileExists(atPath: path),
                   let markdown = try? String(contentsOfFile: path, encoding: .utf8),
                   MarkdownRenderer.isUnmodifiedExport(markdown) {
                    let patched = MarkdownRenderer.applyingPaidPartnershipFrontMatter(
                        to: markdown,
                        isPaid: isPaid
                    )
                    try Data(patched.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                }
                try await database.upsertArticle(updated)
                return updated
            }
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
            warnings: document.warnings,
            processingLog: existing?.processingLog ?? [],
            isPaidPartnership: document.isPaidPartnership == true,
            paidPartnershipChecked: true
        )
        record.lastError = nil
        record.appendProcessingLog("开始处理文章：\(document.title)")
        if record.isPaidPartnership {
            record.appendProcessingLog("已识别 X 官方付费合作（Paid partnership）标记")
        }
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
            record.appendProcessingLog("已缓存 \(document.media.count) 张原图")
            try await database.upsertArticle(record)

            await progress?(imageHost.storesLocalBackup
                ? "正在保存本地图片并写入 \(imageHost.displayName)"
                : "正在上传 \(document.media.count) 张图片到 \(imageHost.displayName)")
            let pendingMedia = document.media.filter {
                $0.remoteURL == nil || (imageHost.storesLocalBackup && !Self.isMediaBackupPath($0.localCachePath, root: root))
            }
            let localURLs = try pendingMedia.map { media -> URL in
                guard let path = media.localCachePath else { throw ArchivePipelineError.missingLocalImage(media.id) }
                return URL(fileURLWithPath: path)
            }
            let uploadURLs = Self.uniqueFileURLs(localURLs)
            let uploadResults = try await imageHost.upload(fileURLs: uploadURLs)
            let resultByPath = try Self.uploadResultsByPath(uploadResults, expectedFileURLs: uploadURLs)
            for index in document.media.indices {
                guard let path = document.media[index].localCachePath,
                      pendingMedia.contains(where: { $0.localCachePath == path }) else { continue }
                let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
                guard let result = resultByPath[normalizedPath] else {
                    throw ImagePipelineError.outputCountMismatch(expected: uploadURLs.count, actual: resultByPath.count)
                }
                try await imageHost.verify(remoteURL: result.remoteURL)
                document.media[index].remoteURL = result.remoteURL
                if let backup = Self.localBackupPath(result.localBackupURL, root: root) {
                    document.media[index].localCachePath = backup
                }
            }
            record.pipelineState = .mediaUploaded
            record.appendProcessingLog("图片处理完成：\(document.media.count) 张；本地备份已校验")
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
            record.appendProcessingLog("已缓存 \(videos.count) 个视频原文件")
            try await database.upsertArticle(record)

            await progress?(imageHost.storesLocalBackup
                ? "正在保存本地视频并写入 \(imageHost.displayName)"
                : "正在上传 \(videos.count) 个视频到 \(imageHost.displayName)")
            let pendingVideos = videos.filter {
                $0.remoteURL == nil || (imageHost.storesLocalBackup && !Self.isMediaBackupPath($0.localCachePath, root: root))
            }
            let localURLs = try pendingVideos.map { video -> URL in
                guard let path = video.localCachePath else {
                    throw ArchivePipelineError.missingLocalVideo(video.id)
                }
                return URL(fileURLWithPath: path)
            }
            let uploadURLs = Self.uniqueFileURLs(localURLs)
            let uploadResults = try await imageHost.upload(fileURLs: uploadURLs)
            let resultByPath = try Self.uploadResultsByPath(uploadResults, expectedFileURLs: uploadURLs)
            for index in videos.indices {
                guard let path = videos[index].localCachePath,
                      pendingVideos.contains(where: { $0.localCachePath == path }) else { continue }
                let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
                guard let result = resultByPath[normalizedPath] else {
                    throw ImagePipelineError.outputCountMismatch(
                        expected: uploadURLs.count,
                        actual: resultByPath.count
                    )
                }
                try await imageHost.verifyVideo(remoteURL: result.remoteURL)
                videos[index].remoteURL = result.remoteURL
                if let backup = Self.localBackupPath(result.localBackupURL, root: root) {
                    videos[index].localCachePath = backup
                }
            }
            document.videos = videos
            record.pipelineState = .mediaUploaded
            record.appendProcessingLog("视频处理完成：\(videos.count) 个；本地备份已校验")
            try await database.upsertArticle(record)
        }

        let creatorDirectory = ArchiveLayout.creatorDirectory(in: root, creator: creator)
        let articlesDirectory = creatorDirectory.appending(path: "articles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: articlesDirectory, withIntermediateDirectories: true)
        let fileName = SafeFileName.articleFileName(title: document.title, publishedAt: document.publishedAt, postID: document.sourcePostID)
        let destination = articlesDirectory.appending(path: fileName)

        await progress?("正在生成并校验 Markdown")
        let markdown = try MarkdownRenderer.render(
            document: document,
            archiveRoot: root,
            markdownDirectory: articlesDirectory
        )
        try MarkdownRenderer.validateRenderedText(
            document: document,
            markdown: markdown,
            archiveRoot: root,
            markdownDirectory: articlesDirectory
        )
        record.pipelineState = .verified
        record.appendProcessingLog("Markdown 内容与媒体顺序校验通过")
        try await database.upsertArticle(record)

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
        record.appendProcessingLog("处理完成，Markdown 已保存")
        try await database.upsertArticle(record)
        try ArchiveIndexWriter.rebuild(root: root, creator: creator)
        await progress?("已完成：\(document.title)")
        return record
    }

    private static func localBackupPath(_ relativeURL: URL?, root: URL) -> String? {
        guard let relativeURL, relativeURL.scheme == nil else { return nil }
        let relativePath = relativeURL.relativeString.removingPercentEncoding ?? relativeURL.relativeString
        let parts = NSString(string: relativePath).pathComponents
        guard relativePath.hasPrefix("media/"), !relativePath.hasPrefix("/"), !parts.contains("..") else {
            return nil
        }
        let resolved = root.appending(path: relativePath).standardizedFileURL
        guard resolved.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return resolved.path
    }

    private static func isMediaBackupPath(_ path: String?, root: URL) -> Bool {
        guard let path else { return false }
        let mediaRoot = root.appending(path: ArchiveLayout.mediaDirectoryName).standardizedFileURL.path
        return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(mediaRoot + "/")
    }

    private static func uniqueFileURLs(_ fileURLs: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return fileURLs.compactMap { fileURL in
            let normalized = fileURL.standardizedFileURL
            return seenPaths.insert(normalized.path).inserted ? normalized : nil
        }
    }

    private static func uploadResultsByPath(
        _ results: [UploadResult],
        expectedFileURLs: [URL]
    ) throws -> [String: UploadResult] {
        let resultByPath = Dictionary(
            results.map { (URL(fileURLWithPath: $0.localPath).standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let expectedPaths = Set(expectedFileURLs.map { $0.standardizedFileURL.path })
        guard results.count == expectedPaths.count,
              resultByPath.count == expectedPaths.count,
              Set(resultByPath.keys) == expectedPaths else {
            throw ImagePipelineError.outputCountMismatch(
                expected: expectedPaths.count,
                actual: resultByPath.count
            )
        }
        return resultByPath
    }

}

public enum ArchiveIndexWriter {
    public static func rebuild(root: URL, creator: Creator) throws {
        let creatorDirectory = ArchiveLayout.creatorDirectory(in: root, creator: creator)
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

        let bloggersDirectory = ArchiveLayout.bloggersDirectory(in: root)
        try FileManager.default.createDirectory(at: bloggersDirectory, withIntermediateDirectories: true)
        let rootIndex = bloggersDirectory.appending(path: "index.md")
        var rootLines = ["# X 长文归档", "", "最后更新：\(Date().formatted(date: .numeric, time: .standard))", ""]
        let creatorDirectories = try FileManager.default.contentsOfDirectory(at: bloggersDirectory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.hasPrefix("@") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for directory in creatorDirectories {
            let encoded = directory.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? directory.lastPathComponent
            rootLines.append("- [\(directory.lastPathComponent)](\(encoded)/index.md)")
        }
        try Data((rootLines.joined(separator: "\n") + "\n").utf8).write(to: rootIndex, options: .atomic)
    }
}
