import Foundation
import os

/// App-wide diagnostic log.
///
/// Every line goes to the unified system log (Console.app, subsystem
/// `ai.defou.markx`) and to a plain-text file under
/// `~/Library/Logs/MarkX/`, so a user can export the recent history in a
/// diagnostic report. The file rotates at `maximumFileSize` and keeps
/// `keptFiles` older copies. Nothing is uploaded; never log cookies, tokens,
/// credentials or article bodies.
public enum MarkXLog {
    public enum Level: String, Sendable {
        case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR"
    }

    public static let subsystem = "ai.defou.markx"
    public static let fileName = "MarkX.log"
    static let maximumFileSize = 2 * 1024 * 1024
    static let keptFiles = 4

    /// `~/Library/Logs/MarkX`. Test runs log to a temporary folder so they
    /// never mix into the user's real log.
    nonisolated(unsafe) public static var directory: URL = isRunningTests
        ? FileManager.default.temporaryDirectory.appending(path: "markx-test-logs", directoryHint: .isDirectory)
        : FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/MarkX", directoryHint: .isDirectory)

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    public static var currentFileURL: URL { directory.appending(path: fileName) }

    /// The current file first, then rotated copies, newest to oldest.
    public static var allFileURLs: [URL] {
        ([currentFileURL] + (1...keptFiles).map { directory.appending(path: "\(fileName).\($0)") })
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let queue = DispatchQueue(label: "ai.defou.markx.log", qos: .utility)
    private static let loggers = OSAllocatedUnfairLock(initialState: [String: Logger]())
    // ISO8601DateFormatter is documented as thread-safe.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    public static func debug(_ category: String, _ message: String) {
        write(.debug, category, message)
    }

    public static func info(_ category: String, _ message: String) {
        write(.info, category, message)
    }

    public static func warning(_ category: String, _ message: String) {
        write(.warning, category, message)
    }

    public static func error(_ category: String, _ message: String) {
        write(.error, category, message)
    }

    public static func write(_ level: Level, _ category: String, _ message: String) {
        let logger = loggers.withLock { cache in
            if let logger = cache[category] { return logger }
            let logger = Logger(subsystem: subsystem, category: category)
            cache[category] = logger
            return logger
        }
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        let line = "\(timestampFormatter.string(from: Date())) [\(level.rawValue)] [\(category)] \(message)\n"
        queue.async { append(line) }
    }

    /// Waits until every queued line is on disk (used before exporting).
    public static func flush() {
        queue.sync {}
    }

    private static func append(_ line: String) {
        let fileManager = FileManager.default
        let url = currentFileURL
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
               size >= maximumFileSize {
                rotate()
            }
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Logging must never take the app down; the system log still has it.
        }
    }

    private static func rotate() {
        let fileManager = FileManager.default
        let oldest = directory.appending(path: "\(fileName).\(keptFiles)")
        try? fileManager.removeItem(at: oldest)
        for index in stride(from: keptFiles - 1, through: 1, by: -1) {
            let source = directory.appending(path: "\(fileName).\(index)")
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: directory.appending(path: "\(fileName).\(index + 1)"))
        }
        try? fileManager.moveItem(at: currentFileURL, to: directory.appending(path: "\(fileName).1"))
    }
}

/// Facts about the disk holding a folder, for choosing the SQLite journal
/// mode and for diagnostic reports.
public struct StorageLocationInfo: Sendable, Equatable {
    public var path: String
    public var fileSystem: String?
    public var isLocalVolume: Bool?
    public var isUbiquitous: Bool
    public var isCloudStorageFolder: Bool
    public var volumeName: String?
    public var availableCapacity: Int64?

    public init(path: String, fileSystem: String?, isLocalVolume: Bool?, isUbiquitous: Bool,
                isCloudStorageFolder: Bool, volumeName: String? = nil, availableCapacity: Int64? = nil) {
        self.path = path
        self.fileSystem = fileSystem
        self.isLocalVolume = isLocalVolume
        self.isUbiquitous = isUbiquitous
        self.isCloudStorageFolder = isCloudStorageFolder
        self.volumeName = volumeName
        self.availableCapacity = availableCapacity
    }

    /// Reads the folder, or its nearest existing parent.
    public static func inspect(_ folder: URL) -> StorageLocationInfo {
        var probe = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [
            .volumeIsLocalKey, .isUbiquitousItemKey, .volumeNameKey, .volumeAvailableCapacityForImportantUsageKey
        ])
        var stats = statfs()
        let fileSystem: String? = statfs(probe.path, &stats) == 0
            ? withUnsafePointer(to: &stats.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            : nil
        return StorageLocationInfo(
            path: folder.path,
            fileSystem: fileSystem,
            isLocalVolume: values?.volumeIsLocal,
            isUbiquitous: values?.isUbiquitousItem == true,
            isCloudStorageFolder: isCloudStoragePath(folder.path),
            volumeName: values?.volumeName,
            availableCapacity: values?.volumeAvailableCapacityForImportantUsage
        )
    }

    /// iCloud Drive, and File Provider folders such as Dropbox, OneDrive and
    /// Google Drive, all live under these paths on current macOS.
    public static func isCloudStoragePath(_ path: String) -> Bool {
        path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/")
            || path.hasSuffix("/Library/Mobile Documents") || path.hasSuffix("/Library/CloudStorage")
    }

    /// SQLite's WAL mode needs shared memory (`-shm`) on a local disk with
    /// reliable POSIX locks. Synced, network and FAT-family volumes fail with
    /// “disk I/O error”, so they use the classic rollback journal instead.
    public var prefersRollbackJournal: Bool {
        if isUbiquitous || isCloudStorageFolder { return true }
        if isLocalVolume == false { return true }
        guard let fileSystem else { return false }
        return !["apfs", "hfs"].contains(fileSystem.lowercased())
    }

    public var summary: String {
        var parts = ["文件系统 \(fileSystem ?? "未知")"]
        parts.append(isLocalVolume == false ? "非本地磁盘" : "本地磁盘")
        if isUbiquitous { parts.append("iCloud 同步目录") }
        if isCloudStorageFolder { parts.append("云盘同步目录") }
        if let volumeName { parts.append("卷 \(volumeName)") }
        if let availableCapacity {
            parts.append("可用 \(ByteCountFormatter.string(fromByteCount: availableCapacity, countStyle: .file))")
        }
        return parts.joined(separator: "，")
    }
}
