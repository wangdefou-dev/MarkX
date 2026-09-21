import Foundation

public enum ArchiveLayoutError: LocalizedError, Sendable {
    case conflictingItem(String)
    case invalidLegacyPath(String)

    public var errorDescription: String? {
        switch self {
        case .conflictingItem(let path):
            "Blogger 目录中已有同名但内容不同的文件，已停止迁移：\(path)"
        case .invalidLegacyPath(let path):
            "无法迁移旧版博主目录：\(path)"
        }
    }
}

public struct ArchiveLayoutMigrationResult: Codable, Hashable, Sendable {
    public var movedCreatorDirectories: [String]
    public var movedRootIndex: Bool
    public var rebasedMarkdownFiles: [String]

    public init(
        movedCreatorDirectories: [String],
        movedRootIndex: Bool,
        rebasedMarkdownFiles: [String] = []
    ) {
        self.movedCreatorDirectories = movedCreatorDirectories
        self.movedRootIndex = movedRootIndex
        self.rebasedMarkdownFiles = rebasedMarkdownFiles
    }

    public var didChange: Bool {
        !movedCreatorDirectories.isEmpty || movedRootIndex || !rebasedMarkdownFiles.isEmpty
    }
}

/// Owns the user-visible archive layout. Internal state remains in the hidden
/// `.x-article-archiver` directory, while user content has exactly two visible
/// top-level containers: `Blogger` and `media`.
public enum ArchiveLayout {
    public static let bloggersDirectoryName = "Blogger"
    public static let mediaDirectoryName = "media"

    public static func bloggersDirectory(in root: URL) -> URL {
        root.appending(path: bloggersDirectoryName, directoryHint: .isDirectory)
    }

    public static func creatorDirectory(in root: URL, creator: Creator) -> URL {
        bloggersDirectory(in: root).appending(
            path: SafeFileName.creatorDirectory(
                handle: creator.username,
                displayName: creator.displayName
            ),
            directoryHint: .isDirectory
        )
    }

    /// Finds a readable Markdown file for this Post ID in the current archive
    /// root. Copied libraries often keep the old machine's absolute path in
    /// SQLite, so the stored path is only the first candidate.
    public static func locateMarkdown(
        postID: String,
        storedPath: String?,
        in root: URL,
        fileManager: FileManager = .default
    ) -> String? {
        var candidates: [String] = []
        if let storedPath, !storedPath.isEmpty {
            candidates.append(storedPath)
            if let migrated = migratedMarkdownPath(storedPath, in: root) {
                candidates.append(migrated)
            }
            if let rebased = rebasedCopiedMarkdownPath(storedPath, in: root) {
                candidates.append(rebased)
            }
        }
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return markdownMatchingPostID(postID, in: root, fileManager: fileManager)
    }

    /// When a library is copied to another Mac, SQLite still stores the old
    /// absolute path. Rebase the `Blogger/...` or legacy `@handle/...` suffix
    /// onto the current archive root.
    public static func rebasedCopiedMarkdownPath(_ path: String, in root: URL) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let marker = "/\(bloggersDirectoryName)/"
        if let range = standardized.range(of: marker) {
            let relative = String(standardized[range.upperBound...])
            guard !relative.isEmpty else { return nil }
            return bloggersDirectory(in: root).appending(path: relative).path
        }
        let components = URL(fileURLWithPath: standardized).pathComponents
        guard let handleIndex = components.lastIndex(where: { $0.hasPrefix("@") }) else {
            return nil
        }
        let relative = components[handleIndex...].joined(separator: "/")
        return bloggersDirectory(in: root).appending(path: relative).path
    }

    public static func markdownMatchingPostID(
        _ postID: String,
        in root: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let suffix = "--\(String(postID.suffix(8))).md"
        let bloggers = bloggersDirectory(in: root)
        guard let creators = try? fileManager.contentsOfDirectory(
            at: bloggers,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for creator in creators {
            let articles = creator.appending(path: "articles", directoryHint: .isDirectory)
            guard let files = try? fileManager.contentsOfDirectory(
                at: articles,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            if let match = files.first(where: { $0.lastPathComponent.hasSuffix(suffix) }) {
                return match.path
            }
        }
        return nil
    }

    /// Records copied to a new Mac without their Markdown files must re-enter
    /// the download queue. Do not treat a committed SQLite row as a completed
    /// archive when the file is gone.
    public static func repairedArticleForAvailableMarkdown(
        _ article: ArchivedArticle,
        markdownPath: String?
    ) -> ArchivedArticle {
        var updated = article
        if let markdownPath {
            updated.markdownPath = markdownPath
            return updated
        }
        guard article.pipelineState == .committed || article.pipelineState == .cancelled else {
            return article
        }
        updated.pipelineState = .discovered
        updated.paidPartnershipChecked = false
        updated.lastError = nil
        updated.appendProcessingLog("本地正文文件不存在，已重新加入下载队列")
        return updated
    }

    public static func migratedMarkdownPath(_ path: String, in root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        guard candidate.path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(candidate.path.dropFirst(rootPath.count + 1))
        guard relative.split(separator: "/", omittingEmptySubsequences: true).first?.hasPrefix("@") == true else {
            return nil
        }
        return bloggersDirectory(in: root).appending(path: relative).path
    }

    @discardableResult
    public static func migrateLegacyLayout(
        in root: URL,
        fileManager: FileManager = .default
    ) throws -> ArchiveLayoutMigrationResult {
        let root = root.standardizedFileURL
        let bloggers = bloggersDirectory(in: root)
        let media = root.appending(path: mediaDirectoryName, directoryHint: .isDirectory)
        let internalRoot = root.appending(path: ".x-article-archiver", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bloggers, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: media, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: internalRoot, withIntermediateDirectories: true)

        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let legacyDirectories = try children.filter { item in
            guard item.lastPathComponent.hasPrefix("@") else { return false }
            return try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }

        for source in legacyDirectories {
            let destination = bloggers.appending(
                path: source.lastPathComponent,
                directoryHint: .isDirectory
            )
            try preflightMerge(source: source, destination: destination, fileManager: fileManager)
        }

        var movedDirectories: [String] = []
        for source in legacyDirectories {
            let destination = bloggers.appending(
                path: source.lastPathComponent,
                directoryHint: .isDirectory
            )
            if fileManager.fileExists(atPath: destination.path) {
                try merge(source: source, destination: destination, fileManager: fileManager)
            } else {
                try fileManager.moveItem(at: source, to: destination)
            }
            movedDirectories.append(source.lastPathComponent)
        }

        let oldRootIndex = root.appending(path: "index.md")
        var movedRootIndex = false
        if fileManager.fileExists(atPath: oldRootIndex.path) {
            var backup = internalRoot.appending(path: "legacy-root-index-before-blogger-layout.md")
            if fileManager.fileExists(atPath: backup.path) {
                if fileManager.contentsEqual(atPath: oldRootIndex.path, andPath: backup.path) {
                    try fileManager.removeItem(at: oldRootIndex)
                } else {
                    backup = internalRoot.appending(path: "legacy-root-index-\(UUID().uuidString).md")
                    try fileManager.moveItem(at: oldRootIndex, to: backup)
                }
            } else {
                try fileManager.moveItem(at: oldRootIndex, to: backup)
            }
            movedRootIndex = true
        }

        let rebasedMarkdownFiles = try rebaseLegacyMediaLinks(
            in: bloggers,
            backupRoot: internalRoot.appending(
                path: "layout-link-backups",
                directoryHint: .isDirectory
            ),
            fileManager: fileManager
        )
        let result = ArchiveLayoutMigrationResult(
            movedCreatorDirectories: movedDirectories.sorted(),
            movedRootIndex: movedRootIndex,
            rebasedMarkdownFiles: rebasedMarkdownFiles
        )
        if result.didChange {
            let manifest = internalRoot.appending(path: "blogger-layout-migration-v1.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: manifest, options: .atomic)
        }
        return result
    }

    private static func rebaseLegacyMediaLinks(
        in bloggers: URL,
        backupRoot: URL,
        fileManager: FileManager
    ) throws -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: bloggers,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var changed: [String] = []
        for case let file as URL in enumerator {
            guard file.pathExtension.lowercased() == "md",
                  file.path.contains("/articles/") else { continue }
            let original = try String(contentsOf: file, encoding: .utf8)
            var updated = original
                .replacingOccurrences(of: "](../../media/", with: "](../../../media/")
                .replacingOccurrences(of: "src=\"../../media/", with: "src=\"../../../media/")
            guard updated != original else { continue }

            let canonicalBloggers = bloggers.resolvingSymlinksInPath()
            let canonicalFile = file.resolvingSymlinksInPath()
            let relativeComponents = canonicalFile.pathComponents.dropFirst(
                canonicalBloggers.pathComponents.count
            )
            let relative = NSString.path(withComponents: Array(relativeComponents))
            let backup = backupRoot.appending(path: relative)
            try fileManager.createDirectory(
                at: backup.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: backup.path) {
                try Data(original.utf8).write(to: backup, options: .atomic)
            }

            if MarkdownRenderer.isUnmodifiedExport(original) {
                let unsigned = updated.components(separatedBy: "\n")
                    .filter { !$0.hasPrefix("export_checksum:") }
                    .joined(separator: "\n")
                updated = MarkdownRenderer.addingExportChecksum(to: unsigned)
            }
            try Data(updated.utf8).write(to: file, options: .atomic)
            changed.append(relative)
        }
        return changed.sorted()
    }

    private static func preflightMerge(
        source: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        var destinationIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory) else {
            return
        }
        guard destinationIsDirectory.boolValue else {
            throw ArchiveLayoutError.conflictingItem(destination.path)
        }
        let sourceItems = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for sourceItem in sourceItems {
            if sourceItem.lastPathComponent == ".DS_Store" { continue }
            let destinationItem = destination.appending(path: sourceItem.lastPathComponent)
            var sourceIsDirectory: ObjCBool = false
            var destinationItemIsDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceItem.path, isDirectory: &sourceIsDirectory) else {
                throw ArchiveLayoutError.invalidLegacyPath(sourceItem.path)
            }
            guard fileManager.fileExists(atPath: destinationItem.path, isDirectory: &destinationItemIsDirectory) else {
                continue
            }
            if sourceIsDirectory.boolValue && destinationItemIsDirectory.boolValue {
                try preflightMerge(source: sourceItem, destination: destinationItem, fileManager: fileManager)
            } else if sourceIsDirectory.boolValue != destinationItemIsDirectory.boolValue
                        || !fileManager.contentsEqual(atPath: sourceItem.path, andPath: destinationItem.path) {
                throw ArchiveLayoutError.conflictingItem(destinationItem.path)
            }
        }
    }

    private static func merge(
        source: URL,
        destination: URL,
        fileManager: FileManager
    ) throws {
        let sourceItems = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for sourceItem in sourceItems {
            if sourceItem.lastPathComponent == ".DS_Store" {
                try fileManager.removeItem(at: sourceItem)
                continue
            }
            let destinationItem = destination.appending(path: sourceItem.lastPathComponent)
            var sourceIsDirectory: ObjCBool = false
            var destinationIsDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: sourceItem.path, isDirectory: &sourceIsDirectory)
            if fileManager.fileExists(atPath: destinationItem.path, isDirectory: &destinationIsDirectory) {
                if sourceIsDirectory.boolValue && destinationIsDirectory.boolValue {
                    try merge(source: sourceItem, destination: destinationItem, fileManager: fileManager)
                } else {
                    try fileManager.removeItem(at: sourceItem)
                }
            } else {
                try fileManager.moveItem(at: sourceItem, to: destinationItem)
            }
        }
        try fileManager.removeItem(at: source)
    }
}
