import Foundation

public struct MediaCacheCleanupResult: Sendable {
    public var removedFiles = 0
    public var removedLogicalBytes: Int64 = 0
}

public enum MediaCacheMaintenance {
    /// Older snapshots may reference a cache whose identical media backup has
    /// since replaced it. Unique files and missing backups are never removed.
    public static func availablePath(_ path: String, root: URL) -> String? {
        if FileManager.default.fileExists(atPath: path) { return path }
        let source = URL(fileURLWithPath: path).standardizedFileURL
        let folder: String
        if source.path.contains("/.x-article-archiver/assets-cache/") { folder = "images" }
        else if source.path.contains("/.x-article-archiver/video-cache/") { folder = "videos" }
        else { return nil }
        let backup = root.appending(path: "media/\(folder)/\(source.lastPathComponent)")
        return FileManager.default.fileExists(atPath: backup.path) ? backup.path : nil
    }

    public static func removeVerifiedDuplicates(root: URL) throws -> MediaCacheCleanupResult {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var result = MediaCacheCleanupResult()
        for (cacheName, mediaName) in [("assets-cache", "images"), ("video-cache", "videos")] {
            let cache = root.appending(path: ".x-article-archiver/\(cacheName)")
            guard FileManager.default.fileExists(atPath: cache.path) else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: cache,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
            for file in files {
                try Task.checkCancellation()
                let backup = root.appending(path: "media/\(mediaName)/\(file.lastPathComponent)")
                guard FileManager.default.fileExists(atPath: backup.path),
                      file.resolvingSymlinksInPath().path.hasPrefix(cache.path + "/"),
                      backup.resolvingSymlinksInPath().path.hasPrefix(root.path + "/media/\(mediaName)/") else { continue }
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                let sourceInfo = try file.resourceValues(forKeys: keys)
                let backupInfo = try backup.resourceValues(forKeys: keys)
                guard sourceInfo.isRegularFile == true, sourceInfo.isSymbolicLink != true,
                      backupInfo.isRegularFile == true, backupInfo.isSymbolicLink != true,
                      let size = sourceInfo.fileSize, size > 0, size == backupInfo.fileSize else { continue }
                let a = try FileHandle(forReadingFrom: file)
                let b = try FileHandle(forReadingFrom: backup)
                defer { try? a.close(); try? b.close() }
                var equal = true
                while true {
                    try Task.checkCancellation()
                    let left = try a.read(upToCount: 1_048_576) ?? Data()
                    let right = try b.read(upToCount: 1_048_576) ?? Data()
                    if left != right { equal = false; break }
                    if left.isEmpty { break }
                }
                if equal {
                    try Task.checkCancellation()
                    try FileManager.default.removeItem(at: file)
                    result.removedFiles += 1
                    result.removedLogicalBytes += Int64(size)
                }
            }
        }
        return result
    }
}
