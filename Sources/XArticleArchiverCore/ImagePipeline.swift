import CryptoKit
import Foundation

public struct ImageHostCapability: Sendable {
    public var name: String
    public var version: String?
    public var isAvailable: Bool
    public var detail: String

    public init(name: String, version: String?, isAvailable: Bool, detail: String) {
        self.name = name
        self.version = version
        self.isAvailable = isAvailable
        self.detail = detail
    }
}

public struct UploadResult: Sendable, Hashable {
    public var localPath: String
    public var remoteURL: URL
    public var localBackupURL: URL?

    public init(localPath: String, remoteURL: URL, localBackupURL: URL? = nil) {
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.localBackupURL = localBackupURL
    }
}

public protocol ImageHostAdapter: Sendable {
    var displayName: String { get }
    var storesLocalBackup: Bool { get }
    func probe() async -> ImageHostCapability
    func upload(fileURLs: [URL]) async throws -> [UploadResult]
    func verify(remoteURL: URL) async throws
    func verifyVideo(remoteURL: URL) async throws
}

public extension ImageHostAdapter {
    var storesLocalBackup: Bool { false }

    func verifyVideo(remoteURL: URL) async throws {
        guard remoteURL.scheme?.lowercased() == "https", let host = remoteURL.host, !host.isEmpty,
              host != "localhost", host != "127.0.0.1", host != "::1" else {
            throw VideoPipelineError.insecureURL(remoteURL.absoluteString)
        }
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VideoPipelineError.invalidHTTPStatus(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VideoPipelineError.invalidHTTPStatus(http.statusCode)
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        guard mime?.hasPrefix("video/") == true || mime == "application/octet-stream" else {
            throw VideoPipelineError.invalidMIME(mime)
        }
    }
}

/// Stores verified media below the user-selected archive root instead of
/// transmitting it to a third-party image host. Returned URLs are deliberately
/// relative to the archive root so Markdown remains portable when the whole
/// archive directory is moved to another disk or Mac.
public struct LocalMediaHostAdapter: ImageHostAdapter {
    public let displayName = "本地存储"
    public let storesLocalBackup = true
    public let archiveRoot: URL

    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot.standardizedFileURL
    }

    public func probe() async -> ImageHostCapability {
        ImageHostCapability(
            name: displayName,
            version: nil,
            isAvailable: FileManager.default.isWritableFile(atPath: archiveRoot.path),
            detail: "图片保存到 media/images，视频保存到 media/videos"
        )
    }

    public func upload(fileURLs: [URL]) async throws -> [UploadResult] {
        guard !fileURLs.isEmpty else { return [] }
        var results: [UploadResult] = []
        for sourceURL in fileURLs {
            try Task.checkCancellation()
            let source = sourceURL.standardizedFileURL
            guard source.isFileURL,
                  FileManager.default.fileExists(atPath: source.path) else {
                throw ImagePipelineError.invalidLocalPath(source.path)
            }
            let ext = source.pathExtension.lowercased()
            let isVideo = ext == "mp4" || ext == "m4v"
            let allowedImageExtensions = Set(["png", "jpg", "jpeg", "gif", "webp", "avif"])
            guard isVideo || allowedImageExtensions.contains(ext) else {
                throw ImagePipelineError.invalidMIME(ext.isEmpty ? nil : ext)
            }
            let digest = try hashFile(source)
            let folder = isVideo ? "videos" : "images"
            let normalizedExtension = isVideo ? "mp4" : ext
            let relativePath = "media/\(folder)/\(digest).\(normalizedExtension)"
            let destination = archiveRoot.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try hashFile(destination) == digest else {
                    throw ImagePipelineError.localFileMismatch(destination.path)
                }
            } else {
                let staging = destination.deletingLastPathComponent().appending(
                    path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
                )
                do {
                    try FileManager.default.copyItem(at: source, to: staging)
                    guard try hashFile(staging) == digest else {
                        throw ImagePipelineError.localFileMismatch(staging.path)
                    }
                    try FileManager.default.moveItem(at: staging, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
            }
            guard let relativeURL = URL(string: relativePath) else {
                throw ImagePipelineError.invalidLocalPath(relativePath)
            }
            results.append(UploadResult(
                localPath: source.path,
                remoteURL: relativeURL,
                localBackupURL: relativeURL
            ))
        }
        return results
    }

    public func verify(remoteURL: URL) async throws {
        let localURL = try resolve(remoteURL, expectedFolder: "images")
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw ImagePipelineError.emptyFile }
        let bytes = [UInt8](try filePrefix(localURL))
        let isImage = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || bytes.starts(with: [0xFF, 0xD8, 0xFF])
            || bytes.starts(with: [0x47, 0x49, 0x46, 0x38])
            || (bytes.count >= 12
                && String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF"
                && String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP")
            || (bytes.count >= 12
                && String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp"
                && String(bytes: bytes[8..<12], encoding: .ascii)?.lowercased().contains("avif") == true)
        guard isImage else { throw ImagePipelineError.invalidMIME(localURL.pathExtension) }
    }

    public func verifyVideo(remoteURL: URL) async throws {
        let localURL = try resolve(remoteURL, expectedFolder: "videos")
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw VideoPipelineError.emptyFile }
        let prefix = try filePrefix(localURL)
        guard prefix.count >= 8,
              String(data: Data(prefix.dropFirst(4).prefix(4)), encoding: .ascii) == "ftyp" else {
            throw VideoPipelineError.invalidMP4
        }
    }

    private func resolve(_ relativeURL: URL, expectedFolder: String) throws -> URL {
        let relativePath = relativeURL.relativeString.removingPercentEncoding ?? relativeURL.relativeString
        guard relativeURL.scheme == nil,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(".."),
              relativePath.hasPrefix("media/\(expectedFolder)/") else {
            throw ImagePipelineError.invalidLocalPath(relativeURL.absoluteString)
        }
        let resolved = archiveRoot.appending(path: relativePath).standardizedFileURL
        guard resolved.path.hasPrefix(archiveRoot.path + "/") else {
            throw ImagePipelineError.invalidLocalPath(resolved.path)
        }
        return resolved
    }

    private func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func filePrefix(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 16) ?? Data()
    }
}

/// Saves every asset below the archive root before uploading it to the selected
/// remote image host. The returned primary URL is the remote URL used by
/// Markdown, while `localBackupURL` keeps the verified portable backup path.
public struct MirroredMediaHostAdapter<Primary: ImageHostAdapter>: ImageHostAdapter {
    public var displayName: String { "\(primary.displayName) + 本地备份" }
    public let storesLocalBackup = true
    public var primary: Primary
    public var local: LocalMediaHostAdapter

    public init(primary: Primary, archiveRoot: URL) {
        self.primary = primary
        self.local = LocalMediaHostAdapter(archiveRoot: archiveRoot)
    }

    public func probe() async -> ImageHostCapability {
        let localCapability = await local.probe()
        let primaryCapability = await primary.probe()
        return ImageHostCapability(
            name: displayName,
            version: primaryCapability.version,
            isAvailable: localCapability.isAvailable && primaryCapability.isAvailable,
            detail: primaryCapability.isAvailable
                ? "远程图床可用；图片和视频同时保存在本地 media 目录"
                : primaryCapability.detail
        )
    }

    public func upload(fileURLs: [URL]) async throws -> [UploadResult] {
        guard !fileURLs.isEmpty else { return [] }
        // The download cache is content-addressed, so two distinct Article
        // image blocks can legitimately point at the same local file. Upload
        // each physical file once, then expand the result back to the caller's
        // original order. Dictionary(uniqueKeysWithValues:) would otherwise
        // trap the entire process when it sees those duplicate paths.
        var seenPaths = Set<String>()
        let uniqueFileURLs = fileURLs.compactMap { fileURL -> URL? in
            let normalized = fileURL.standardizedFileURL
            return seenPaths.insert(normalized.path).inserted ? normalized : nil
        }

        let localResults = try await local.upload(fileURLs: uniqueFileURLs)
        for result in localResults {
            let ext = URL(fileURLWithPath: result.localPath).pathExtension.lowercased()
            if ext == "mp4" || ext == "m4v" {
                try await local.verifyVideo(remoteURL: result.remoteURL)
            } else {
                try await local.verify(remoteURL: result.remoteURL)
            }
        }

        let primaryResults = try await primary.upload(fileURLs: uniqueFileURLs)
        guard primaryResults.count == localResults.count else {
            throw ImagePipelineError.outputCountMismatch(
                expected: localResults.count,
                actual: primaryResults.count
            )
        }

        let localByPath = Dictionary(
            localResults.map { (URL(fileURLWithPath: $0.localPath).standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var combinedByPath: [String: UploadResult] = [:]
        for result in primaryResults {
            let path = URL(fileURLWithPath: result.localPath).standardizedFileURL.path
            guard combinedByPath[path] == nil, let localResult = localByPath[path] else {
                throw ImagePipelineError.outputCountMismatch(
                    expected: localResults.count,
                    actual: combinedByPath.count
                )
            }
            combinedByPath[path] = UploadResult(
                localPath: path,
                remoteURL: result.remoteURL,
                localBackupURL: localResult.remoteURL
            )
        }
        guard combinedByPath.count == uniqueFileURLs.count else {
            throw ImagePipelineError.outputCountMismatch(
                expected: uniqueFileURLs.count,
                actual: combinedByPath.count
            )
        }

        return try fileURLs.map { fileURL in
            let path = fileURL.standardizedFileURL.path
            guard let result = combinedByPath[path] else {
                throw ImagePipelineError.outputCountMismatch(
                    expected: uniqueFileURLs.count,
                    actual: combinedByPath.count
                )
            }
            return result
        }
    }

    public func verify(remoteURL: URL) async throws {
        try await primary.verify(remoteURL: remoteURL)
    }

    public func verifyVideo(remoteURL: URL) async throws {
        try await primary.verifyVideo(remoteURL: remoteURL)
    }
}

public enum ImagePipelineError: LocalizedError, Sendable {
    case hostUnavailable(String)
    case processFailed(Int32, String)
    case invalidOutput(String)
    case outputCountMismatch(expected: Int, actual: Int)
    case insecureURL(String)
    case invalidHTTPStatus(Int)
    case invalidMIME(String?)
    case fileTooLarge(Int64)
    case emptyFile
    case invalidLocalPath(String)
    case localFileMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .hostUnavailable(let detail): "媒体存储不可用：\(detail)"
        case .processFailed(let code, let detail): "uPic 上传失败（\(code)）：\(detail)"
        case .invalidOutput(let detail): "无法解析图床返回结果：\(detail)"
        case .outputCountMismatch(let expected, let actual): "图床返回 URL 数量不一致，应为 \(expected)，实际为 \(actual)"
        case .insecureURL(let value): "图床返回了不安全或无效的 URL：\(value)"
        case .invalidHTTPStatus(let code): "远程图片验证失败（HTTP \(code)）"
        case .invalidMIME(let mime): "远程内容不是可识别图片（\(mime ?? "无 MIME")）"
        case .fileTooLarge(let bytes): "图片超过 50 MB 限制（\(bytes) bytes）"
        case .emptyFile: "图片文件为空"
        case .invalidLocalPath(let path): "本地媒体路径无效或超出归档目录：\(path)"
        case .localFileMismatch(let path): "本地媒体复制后校验失败：\(path)"
        }
    }
}

public enum VideoPipelineError: LocalizedError, Sendable {
    case insecureURL(String)
    case invalidHTTPStatus(Int)
    case invalidMIME(String?)
    case invalidMP4
    case fileTooLarge(Int64)
    case emptyFile

    public var errorDescription: String? {
        switch self {
        case .insecureURL(let value): "视频地址不安全或无效：\(value)"
        case .invalidHTTPStatus(let code): "视频下载或回读失败（HTTP \(code)）"
        case .invalidMIME(let mime): "返回内容不是可识别视频（\(mime ?? "无 MIME")）"
        case .invalidMP4: "下载结果不是有效的 MP4 视频"
        case .fileTooLarge(let bytes): "视频超过 2 GB 限制（\(bytes) bytes）"
        case .emptyFile: "视频文件为空"
        }
    }
}

public struct VideoDownloader: Sendable {
    private let session: URLSession
    public var maximumBytes: Int64

    public init(session: URLSession = .shared, maximumBytes: Int64 = 2 * 1_024 * 1_024 * 1_024) {
        self.session = session
        self.maximumBytes = maximumBytes
    }

    public func cache(_ video: VideoAsset, in cacheDirectory: URL) async throws -> VideoAsset {
        var mostRecentError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                return try await cacheOnce(video, in: cacheDirectory)
            } catch {
                mostRecentError = error
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 700 : 1_800))
            }
        }
        throw mostRecentError ?? VideoPipelineError.emptyFile
    }

    private func cacheOnce(_ video: VideoAsset, in cacheDirectory: URL) async throws -> VideoAsset {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var request = URLRequest(url: video.sourceURL)
        request.timeoutInterval = 180
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VideoPipelineError.invalidHTTPStatus(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VideoPipelineError.invalidHTTPStatus(http.statusCode)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw VideoPipelineError.emptyFile }
        guard size <= maximumBytes else { throw VideoPipelineError.fileTooLarge(size) }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        guard mime?.hasPrefix("video/") == true || mime == "application/octet-stream" else {
            throw VideoPipelineError.invalidMIME(mime)
        }

        let prefix = try Data(contentsOf: temporaryURL, options: .mappedIfSafe).prefix(16)
        guard prefix.count >= 8,
              String(data: Data(prefix.dropFirst(4).prefix(4)), encoding: .ascii) == "ftyp" else {
            throw VideoPipelineError.invalidMP4
        }
        let digest = try hashVideoFile(temporaryURL)
        let destination = cacheDirectory.appending(path: "\(digest).mp4")
        if !FileManager.default.fileExists(atPath: destination.path) {
            let staging = cacheDirectory.appending(path: ".\(UUID().uuidString).tmp")
            try FileManager.default.copyItem(at: temporaryURL, to: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        var updated = video
        updated.localCachePath = destination.path
        updated.sha256 = digest
        return updated
    }

    private func hashVideoFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct UPicAdapter: ImageHostAdapter {
    public let displayName = "uPic 图床"
    public var executableURL: URL
    private let session: URLSession

    public init(
        executableURL: URL = URL(fileURLWithPath: "/Applications/uPic.app/Contents/MacOS/uPic"),
        session: URLSession = .shared
    ) {
        self.executableURL = executableURL
        self.session = session
    }

    public func probe() async -> ImageHostCapability {
        let available = FileManager.default.isExecutableFile(atPath: executableURL.path)
        let infoURL = executableURL.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
        let info = NSDictionary(contentsOf: infoURL)
        let version = info?["CFBundleShortVersionString"] as? String
        return ImageHostCapability(
            name: displayName,
            version: version,
            isAvailable: available,
            detail: available ? "已发现 uPic，可使用它当前选中的默认图床" : "没有在 Applications 中找到可执行的 uPic"
        )
    }

    public func upload(fileURLs: [URL]) async throws -> [UploadResult] {
        guard !fileURLs.isEmpty else { return [] }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ImagePipelineError.hostUnavailable("没有找到 uPic")
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = self.executableURL
            process.arguments = ["-u"] + fileURLs.map(\.path) + ["-o", "url"]
            process.standardOutput = stdout
            process.standardError = stderr
            var environment = [String: String]()
            for key in ["PATH", "TMPDIR", "LANG", "LC_ALL", "HOME", "USER"] {
                if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
            }
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw ImagePipelineError.processFailed(process.terminationStatus, Self.safeProcessMessage(error.isEmpty ? output : error))
            }
            let urls = try UPicOutputParser.parse(output)
            guard urls.count == fileURLs.count else {
                throw ImagePipelineError.outputCountMismatch(expected: fileURLs.count, actual: urls.count)
            }
            return zip(fileURLs, urls).map { UploadResult(localPath: $0.0.path, remoteURL: $0.1) }
        }.value
    }

    public func verify(remoteURL: URL) async throws {
        guard remoteURL.scheme?.lowercased() == "https", let host = remoteURL.host, !host.isEmpty,
              host != "localhost", host != "127.0.0.1", host != "::1" else {
            throw ImagePipelineError.insecureURL(remoteURL.absoluteString)
        }
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImagePipelineError.invalidHTTPStatus(0) }
        guard (200..<300).contains(http.statusCode) else { throw ImagePipelineError.invalidHTTPStatus(http.statusCode) }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        guard mime?.hasPrefix("image/") == true || mime == "application/octet-stream" else {
            throw ImagePipelineError.invalidMIME(mime)
        }
    }

    private static func safeProcessMessage(_ message: String) -> String {
        let first = message.split(separator: "\n").prefix(3).joined(separator: " ")
        return String(first.prefix(300))
    }
}

public enum UPicOutputParser {
    public static func parse(_ output: String) throws -> [URL] {
        let lines = output.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let markerIndex = lines.lastIndex(where: { $0.localizedCaseInsensitiveContains("Output URL") })
        let candidates = markerIndex.map { Array(lines.dropFirst($0 + 1)) } ?? lines
        let urls = candidates.compactMap { line -> URL? in
            guard !line.isEmpty, let url = URL(string: line), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
            return url
        }
        guard !urls.isEmpty else {
            throw ImagePipelineError.invalidOutput(String(output.prefix(300)))
        }
        return urls
    }
}

public struct ImageDownloader: Sendable {
    private let session: URLSession
    public var maximumBytes: Int64

    public init(session: URLSession = .shared, maximumBytes: Int64 = 50 * 1_024 * 1_024) {
        self.session = session
        self.maximumBytes = maximumBytes
    }

    public func cache(_ media: MediaAsset, in cacheDirectory: URL) async throws -> MediaAsset {
        var mostRecentError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                return try await cacheOnce(media, in: cacheDirectory)
            } catch {
                mostRecentError = error
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 450 : 1_200))
            }
        }
        throw mostRecentError ?? ImagePipelineError.emptyFile
    }

    private func cacheOnce(_ media: MediaAsset, in cacheDirectory: URL) async throws -> MediaAsset {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var request = URLRequest(url: media.sourceURL)
        request.timeoutInterval = 60
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImagePipelineError.invalidHTTPStatus(0) }
        guard (200..<300).contains(http.statusCode) else { throw ImagePipelineError.invalidHTTPStatus(http.statusCode) }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw ImagePipelineError.emptyFile }
        guard size <= maximumBytes else { throw ImagePipelineError.fileTooLarge(size) }

        let prefix = try Data(contentsOf: temporaryURL, options: .mappedIfSafe).prefix(16)
        let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        let ext = try imageExtension(mime: mime, prefix: Data(prefix))
        let digest = try hashFile(temporaryURL)
        let destination = cacheDirectory.appending(path: "\(digest).\(ext)")
        if !FileManager.default.fileExists(atPath: destination.path) {
            let staging = cacheDirectory.appending(path: ".\(UUID().uuidString).tmp")
            try FileManager.default.copyItem(at: temporaryURL, to: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        var updated = media
        updated.localCachePath = destination.path
        updated.sha256 = digest
        return updated
    }

    private func imageExtension(mime: String?, prefix: Data) throws -> String {
        let bytes = [UInt8](prefix)
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if bytes.count >= 12,
           String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return "webp" }
        if bytes.count >= 12,
           String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp",
           String(bytes: bytes[8..<12], encoding: .ascii)?.lowercased().contains("avif") == true { return "avif" }
        if mime?.contains("png") == true { return "png" }
        if mime?.contains("jpeg") == true || mime?.contains("jpg") == true { return "jpg" }
        if mime?.contains("webp") == true { return "webp" }
        if mime?.contains("gif") == true { return "gif" }
        throw ImagePipelineError.invalidMIME(mime)
    }

    private func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
