import Foundation

public enum ArchiveDirectorySyncError: LocalizedError, Sendable {
    case sourceMissing(String)
    case sameDirectory
    case nestedDirectory
    case symbolicLink(String)
    case conflictingFile(String)
    case unsupportedItem(String)
    case fileOperation(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            "当前归档目录不存在：\(path)"
        case .sameDirectory:
            "选择的目录就是当前归档目录"
        case .nestedDirectory:
            "新旧归档目录不能互相包含；请另选一个独立目录"
        case .symbolicLink(let path):
            "归档中包含不安全的符号链接，已停止同步：\(path)"
        case .conflictingFile(let path):
            "目标目录已有同名但内容不同的文件：\(path)。为避免覆盖另一套资料库，请选择空目录"
        case .unsupportedItem(let path):
            "归档中包含无法同步的文件类型：\(path)"
        case .fileOperation(let detail):
            "同步归档目录失败：\(detail)"
        }
    }
}

public struct ArchiveDirectorySyncResult: Hashable, Sendable {
    public var copiedFileCount: Int
    public var reusedFileCount: Int
    public var copiedByteCount: Int64

    public init(copiedFileCount: Int, reusedFileCount: Int, copiedByteCount: Int64) {
        self.copiedFileCount = copiedFileCount
        self.reusedFileCount = reusedFileCount
        self.copiedByteCount = copiedByteCount
    }
}

/// Copies one archive root into another without deleting the source or
/// overwriting a different destination file. The operation is retryable: files
/// copied by an interrupted run compare equal and are reused on the next run.
public enum ArchiveDirectorySynchronizer {
    private struct Item {
        var sourceURL: URL
        var destinationURL: URL
        var relativePath: String
        var isDirectory: Bool
        var fileSize: Int64
    }

    public static func synchronize(
        from source: URL,
        to destination: URL,
        replaceableRelativePaths: Set<String> = [],
        fileManager: FileManager = .default
    ) throws -> ArchiveDirectorySyncResult {
        let sourceRoot = source.standardizedFileURL.resolvingSymlinksInPath()
        let destinationRoot = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard isDirectory(sourceRoot, fileManager: fileManager) else {
            throw ArchiveDirectorySyncError.sourceMissing(sourceRoot.path)
        }
        guard sourceRoot.path != destinationRoot.path else {
            throw ArchiveDirectorySyncError.sameDirectory
        }
        guard !isDescendant(destinationRoot, of: sourceRoot),
              !isDescendant(sourceRoot, of: destinationRoot) else {
            throw ArchiveDirectorySyncError.nestedDirectory
        }

        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let items = try collectItems(
            from: sourceRoot,
            to: destinationRoot,
            fileManager: fileManager
        )

        var reusedFileCount = 0
        for item in items {
            try checkCancellation()
            var isDestinationDirectory: ObjCBool = false
            let destinationExists = fileManager.fileExists(
                atPath: item.destinationURL.path,
                isDirectory: &isDestinationDirectory
            )
            guard destinationExists else { continue }
            if item.isDirectory {
                guard isDestinationDirectory.boolValue else {
                    throw ArchiveDirectorySyncError.conflictingFile(item.relativePath)
                }
            } else {
                guard !isDestinationDirectory.boolValue else {
                    throw ArchiveDirectorySyncError.conflictingFile(item.relativePath)
                }
                if fileManager.contentsEqual(
                    atPath: item.sourceURL.path,
                    andPath: item.destinationURL.path
                ) {
                    reusedFileCount += 1
                } else if !replaceableRelativePaths.contains(item.relativePath) {
                    throw ArchiveDirectorySyncError.conflictingFile(item.relativePath)
                }
            }
        }

        var copiedFileCount = 0
        var copiedByteCount: Int64 = 0
        for item in items.sorted(by: itemSort) {
            try checkCancellation()
            if item.isDirectory {
                try fileManager.createDirectory(at: item.destinationURL, withIntermediateDirectories: true)
                continue
            }
            let destinationExists = fileManager.fileExists(atPath: item.destinationURL.path)
            let shouldReplace = destinationExists && replaceableRelativePaths.contains(item.relativePath)
            guard !destinationExists || shouldReplace else { continue }
            try fileManager.createDirectory(
                at: item.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temporaryURL = item.destinationURL.deletingLastPathComponent().appending(
                path: ".\(item.destinationURL.lastPathComponent).x-archive-sync-\(UUID().uuidString)"
            )
            do {
                try fileManager.copyItem(at: item.sourceURL, to: temporaryURL)
                if shouldReplace {
                    _ = try fileManager.replaceItemAt(
                        item.destinationURL,
                        withItemAt: temporaryURL,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: item.destinationURL)
                }
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw ArchiveDirectorySyncError.fileOperation(error.localizedDescription)
            }
            copiedFileCount += 1
            copiedByteCount += item.fileSize
        }

        for item in items where !item.isDirectory {
            try checkCancellation()
            guard fileManager.contentsEqual(
                atPath: item.sourceURL.path,
                andPath: item.destinationURL.path
            ) else {
                throw ArchiveDirectorySyncError.fileOperation("复制后校验失败：\(item.relativePath)")
            }
        }

        return ArchiveDirectorySyncResult(
            copiedFileCount: copiedFileCount,
            reusedFileCount: reusedFileCount,
            copiedByteCount: copiedByteCount
        )
    }

    public static func rebasedPath(_ path: String, from source: URL, to destination: URL) -> String? {
        guard let relativePath = relativePath(for: path, under: source) else { return nil }
        return destination.standardizedFileURL.appending(path: relativePath).path
    }

    public static func relativePath(for path: String, under root: URL) -> String? {
        let rootPath = normalizedRootPath(root)
        let candidatePath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidatePath.hasPrefix(rootPath + "/") else { return nil }
        let relativePath = String(candidatePath.dropFirst(rootPath.count + 1))
        return relativePath.isEmpty ? nil : relativePath
    }

    private static func collectItems(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws -> [Item] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ArchiveDirectorySyncError.fileOperation("无法读取当前归档目录")
        }

        var items: [Item] = []
        let sourcePath = normalizedRootPath(source)
        for case let itemURL as URL in enumerator {
            try checkCancellation()
            let itemPath = itemURL.standardizedFileURL.path
            guard itemPath.hasPrefix(sourcePath + "/") else {
                throw ArchiveDirectorySyncError.fileOperation("无法计算归档文件的相对路径")
            }
            let relativePath = String(itemPath.dropFirst(sourcePath.count + 1))
            let values = try itemURL.resourceValues(forKeys: Set(keys))
            if shouldSkip(relativePath) {
                // `skipDescendants()` is only valid for a directory. Calling it
                // while the current item is a nested .DS_Store or SQLite WAL
                // file can cause Foundation to skip later siblings such as an
                // author's entire `articles/` directory.
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isSymbolicLink == true {
                throw ArchiveDirectorySyncError.symbolicLink(relativePath)
            }
            guard values.isDirectory == true || values.isRegularFile == true else {
                throw ArchiveDirectorySyncError.unsupportedItem(relativePath)
            }
            items.append(Item(
                sourceURL: itemURL,
                destinationURL: destination.appending(path: relativePath),
                relativePath: relativePath,
                isDirectory: values.isDirectory == true,
                fileSize: Int64(values.fileSize ?? 0)
            ))
        }
        if let enumerationError {
            throw ArchiveDirectorySyncError.fileOperation(enumerationError.localizedDescription)
        }
        return items
    }

    private static func shouldSkip(_ relativePath: String) -> Bool {
        let name = URL(fileURLWithPath: relativePath).lastPathComponent
        if name == ".DS_Store" { return true }
        return relativePath == ".x-article-archiver/archive.sqlite-wal"
            || relativePath == ".x-article-archiver/archive.sqlite-shm"
    }

    private static func itemSort(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        let lhsDepth = lhs.relativePath.split(separator: "/").count
        let rhsDepth = rhs.relativePath.split(separator: "/").count
        if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
        return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        normalizedRootPath(candidate).hasPrefix(normalizedRootPath(parent) + "/")
    }

    private static func normalizedRootPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func checkCancellation() throws {
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
            throw CancellationError()
        }
    }
}
