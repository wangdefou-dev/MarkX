import CryptoKit
import Foundation

/// The release receipt the website publishes at `/release.json`.
public struct ReleaseManifest: Decodable, Equatable, Sendable {
    public var version: String
    public var build: String
    public var sha256: String
    public var url: URL?
    public var notes: [String]?

    public init(version: String, build: String, sha256: String, url: URL? = nil, notes: [String]? = nil) {
        self.version = version
        self.build = build
        self.sha256 = sha256
        self.url = url
        self.notes = notes
    }

    /// Older receipts carry no URL; the DMG lives at a fixed, immutable path.
    public var downloadURL: URL {
        url ?? URL(string: "https://download.markx.defou.ai/\(version)/MarkX-\(version).dmg")!
    }
}

public enum AppUpdatePolicy {
    public static let manifestURL = URL(string: "https://markx.defou.ai/release.json")!
    public static let trustedDownloadHosts: Set<String> = ["download.markx.defou.ai", "1want.link"]

    static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Compares dotted versions numerically, then build numbers.
    public static func isNewer(_ manifest: ReleaseManifest, thanVersion version: String, build: String) -> Bool {
        var lhs = components(manifest.version)
        var rhs = components(version)
        let count = max(lhs.count, rhs.count)
        lhs += Array(repeating: 0, count: count - lhs.count)
        rhs += Array(repeating: 0, count: count - rhs.count)
        if lhs != rhs { return lhs.lexicographicallyPrecedes(rhs) == false }
        return (Int(manifest.build) ?? 0) > (Int(build) ?? 0)
    }

    public static func validate(_ manifest: ReleaseManifest, allowAnyHost: Bool = false) throws {
        let hex = manifest.sha256.lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit),
              !components(manifest.version).isEmpty, Int(manifest.build) != nil else {
            throw AppUpdateError.invalidManifest
        }
        let url = manifest.downloadURL
        guard allowAnyHost || (url.scheme == "https" && trustedDownloadHosts.contains(url.host ?? "")) else {
            throw AppUpdateError.untrustedDownload(url)
        }
    }
}

public enum AppUpdateError: LocalizedError, Equatable {
    case invalidManifest
    case server(Int)
    case untrustedDownload(URL)
    case checksumMismatch
    case diskImage(String)
    case appMissing
    case bundleMismatch(String)
    case signature(String)
    case install(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: "更新信息格式不正确。"
        case .server(let status): "更新服务器暂时不可用（HTTP \(status)），请稍后再试。"
        case .untrustedDownload(let url): "更新地址不受信任：\(url.absoluteString)"
        case .checksumMismatch: "下载的安装包校验值不一致，已丢弃。"
        case .diskImage(let detail): "无法打开安装包：\(detail)"
        case .appMissing: "安装包中没有找到 MarkX。"
        case .bundleMismatch(let detail): "安装包与当前应用不匹配：\(detail)"
        case .signature(let detail): "安装包签名校验失败：\(detail)"
        case .install(let detail): "无法替换应用：\(detail)"
        }
    }
}

public enum AppUpdateInstaller {
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies the DMG, copies its app into `directory` and checks that it is
    /// the expected, validly signed bundle. Returns the staged app.
    public static func stageApp(
        fromDiskImage dmg: URL,
        expectedSHA256: String,
        expectedBundleID: String,
        expectedVersion: String,
        in directory: URL
    ) throws -> URL {
        guard try sha256(of: dmg) == expectedSHA256.lowercased() else {
            throw AppUpdateError.checksumMismatch
        }
        let mountPoint = directory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let attach = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                              "-mountpoint", mountPoint.path, dmg.path])
        guard attach.status == 0 else {
            let reason = attach.output.split(separator: "\n").filter { !$0.contains("WARNING") }.joined(separator: " ")
            throw AppUpdateError.diskImage(reason.isEmpty ? "hdiutil 退出码 \(attach.status)" : reason)
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"]) }

        let contents = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let source = contents.first(where: { $0.pathExtension == "app" && !$0.lastPathComponent.hasPrefix(".") }) else {
            throw AppUpdateError.appMissing
        }
        let staged = directory.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try? FileManager.default.removeItem(at: staged)
        let copy = run("/usr/bin/ditto", [source.path, staged.path])
        guard copy.status == 0 else { throw AppUpdateError.diskImage(copy.output) }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        let info = Bundle(url: staged)?.infoDictionary ?? [:]
        guard info["CFBundleIdentifier"] as? String == expectedBundleID else {
            throw AppUpdateError.bundleMismatch(info["CFBundleIdentifier"] as? String ?? "未知标识")
        }
        guard info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw AppUpdateError.bundleMismatch("版本为 \(info["CFBundleShortVersionString"] as? String ?? "未知")")
        }
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        guard verify.status == 0 else { throw AppUpdateError.signature(verify.output) }
        return staged
    }

    /// Moves the installed app to the Trash and puts the staged one in its
    /// place. The running process keeps working from the trashed copy until it
    /// quits. Restores the old app if the move fails.
    @discardableResult
    public static func replace(installedApp: URL, with staged: URL) throws -> URL? {
        let fileManager = FileManager.default
        var trashed: NSURL?
        do {
            try fileManager.trashItem(at: installedApp, resultingItemURL: &trashed)
        } catch {
            throw AppUpdateError.install(error.localizedDescription)
        }
        do {
            try fileManager.moveItem(at: staged, to: installedApp)
        } catch {
            if let trashed = trashed as URL? {
                try? fileManager.moveItem(at: trashed, to: installedApp)
            }
            throw AppUpdateError.install(error.localizedDescription)
        }
        return trashed as URL?
    }

    /// Opens `app` once process `pid` has exited.
    public static func relaunch(_ app: URL, afterProcessExits pid: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                             "markx-relaunch", String(pid), app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}
