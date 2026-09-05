import Darwin
import Foundation

public struct UPicS3Profile: Sendable {
    public var name: String
    public var configuration: S3ImageHostConfiguration
    public var accessKey: String
    public var secretKey: String

    public init(
        name: String,
        configuration: S3ImageHostConfiguration,
        accessKey: String,
        secretKey: String
    ) {
        self.name = name
        self.configuration = configuration
        self.accessKey = accessKey
        self.secretKey = secretKey
    }
}

public enum UPicConfigurationError: LocalizedError, Sendable {
    case preferencesNotFound
    case unreadablePreferences
    case noHosts
    case defaultHostNotFound
    case unsupportedDefaultHost(String)
    case incompleteS3Configuration(String)
    case preferencesExportTimedOut

    public var errorDescription: String? {
        switch self {
        case .preferencesNotFound:
            "没有找到 uPic 的本机配置文件"
        case .unreadablePreferences:
            "uPic 配置无法读取"
        case .noHosts:
            "uPic 尚未配置图床"
        case .defaultHostNotFound:
            "uPic 当前默认图床已失效，请先在 uPic 中重新选择"
        case .unsupportedDefaultHost(let type):
            "uPic 当前默认图床是 \(type)；此版本可原生接管 S3 / Cloudflare R2"
        case .incompleteS3Configuration(let detail):
            "uPic 当前的 S3/R2 配置不完整：\(detail)"
        case .preferencesExportTimedOut:
            "uPic 配置读取超时，请确认 uPic 可以正常打开后重试"
        }
    }
}

public enum UPicConfigurationReader {
    public static func defaultPreferencesURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDirectory.appending(path: "Library/Containers/com.svend.uPic.macos/Data/Library/Preferences/com.svend.uPic.macos.plist"),
            homeDirectory.appending(path: "Library/Preferences/com.svend.uPic.macos.plist")
        ]
    }

    public static func readDefaultS3(preferencesURL: URL? = nil) throws -> UPicS3Profile {
        let data: Data
        if let preferencesURL {
            guard let fileData = try? Data(contentsOf: preferencesURL) else {
                throw UPicConfigurationError.unreadablePreferences
            }
            data = fileData
        } else {
            // The app itself must not open uPic's protected container plist.
            // Export to a temporary file instead of a Pipe: waiting for Pipe
            // EOF previously stranded `defaults` children and froze capture.
            data = try exportedPreferencesData()
        }

        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = propertyList as? [String: Any] else {
            throw UPicConfigurationError.unreadablePreferences
        }

        guard let rawItems = root["uPic_hostItems"] as? [String], !rawItems.isEmpty else {
            throw UPicConfigurationError.noHosts
        }
        let defaultID = root["uPic_DefaultHostId"] as? String
        var decodedItems: [[String: Any]] = []
        for rawItem in rawItems {
            guard let itemData = rawItem.data(using: .utf8),
                  let item = try? JSONSerialization.jsonObject(with: itemData) as? [String: Any] else { continue }
            decodedItems.append(item)
        }
        guard !decodedItems.isEmpty else { throw UPicConfigurationError.noHosts }

        let selected: [String: Any]?
        if let defaultID, !defaultID.isEmpty {
            selected = decodedItems.first { ($0["id"] as? String) == defaultID }
        } else {
            selected = decodedItems.first
        }
        guard let selected else { throw UPicConfigurationError.defaultHostNotFound }

        let type = (selected["type"] as? String ?? "未知类型").lowercased()
        guard type == "s3" else { throw UPicConfigurationError.unsupportedDefaultHost(type) }
        guard let innerRaw = selected["data"] as? String,
              let innerData = innerRaw.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] else {
            throw UPicConfigurationError.incompleteS3Configuration("配置内容无法解析")
        }

        let endpoint = try secureURL(inner["endpoint"] as? String, field: "Endpoint")
        let publicBaseURL = try secureURL(inner["domain"] as? String, field: "公开访问地址")
        guard let accessKey = nonempty(inner["accessKey"] as? String) else {
            throw UPicConfigurationError.incompleteS3Configuration("Access Key 为空")
        }
        guard let secretKey = nonempty(inner["secretKey"] as? String) else {
            throw UPicConfigurationError.incompleteS3Configuration("Secret Key 为空")
        }

        var bucket = (inner["bucket"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !bucket.isEmpty, endpoint.pathComponents.last == bucket {
            // uPic sometimes stores the bucket in both fields. Avoid uploading to /bucket/bucket/key.
            bucket = ""
        }
        let saveKeyPath = inner["saveKeyPath"] as? String ?? "uPic/{filename}{.suffix}"
        let prefix = keyPrefix(from: saveKeyPath)
        let region = inferredRegion(endpoint: endpoint)
        let name = nonempty(selected["name"] as? String) ?? "uPic 默认 S3/R2"

        return UPicS3Profile(
            name: name,
            configuration: S3ImageHostConfiguration(
                endpoint: endpoint,
                bucket: bucket,
                publicBaseURL: publicBaseURL,
                region: region,
                keyPrefix: prefix
            ),
            accessKey: accessKey,
            secretKey: secretKey
        )
    }

    private static func exportedPreferencesData() throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "x-article-archiver-upic-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputDescriptor = open(
            outputURL.path,
            O_WRONLY | O_CREAT | O_TRUNC,
            S_IRUSR | S_IWUSR
        )
        guard outputDescriptor >= 0 else {
            throw UPicConfigurationError.unreadablePreferences
        }
        defer { close(outputDescriptor) }

        // Foundation.Process can leave its termination state stale when this
        // synchronous helper runs inside a detached task owned by a SwiftUI
        // app. Spawn `defaults` directly so the same code path behaves in the
        // installed GUI and in tests. A regular file also avoids Pipe EOF
        // deadlocks and the preferences-daemon stall seen with an export path.
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw UPicConfigurationError.unreadablePreferences
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawn_file_actions_adddup2(&fileActions, outputDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(
                &fileActions,
                STDERR_FILENO,
                "/dev/null",
                O_WRONLY,
                0
              ) == 0 else {
            throw UPicConfigurationError.unreadablePreferences
        }

        let argumentStrings = [
            "defaults",
            "export",
            "com.svend.uPic.macos",
            "-"
        ]
        var arguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) } + [nil]
        defer {
            for argument in arguments where argument != nil {
                free(argument)
            }
        }

        var childPID: pid_t = 0
        let spawnResult = posix_spawn(
            &childPID,
            "/usr/bin/defaults",
            &fileActions,
            nil,
            &arguments,
            environ
        )
        guard spawnResult == 0 else {
            throw hasPreferencesFile ? UPicConfigurationError.unreadablePreferences : UPicConfigurationError.preferencesNotFound
        }

        let deadline = Date().addingTimeInterval(3)
        var childCompleted = false
        var waitStatus: Int32 = 0
        while Date() < deadline {
            let result = waitpid(childPID, &waitStatus, WNOHANG)
            if result == childPID {
                childCompleted = true
                break
            }
            if result == -1 && errno != EINTR {
                throw UPicConfigurationError.unreadablePreferences
            }
            usleep(20_000)
        }
        if !childCompleted {
            kill(childPID, SIGTERM)
            usleep(200_000)
            if waitpid(childPID, &waitStatus, WNOHANG) == 0 {
                kill(childPID, SIGKILL)
            }
            _ = waitpid(childPID, &waitStatus, 0)
            throw UPicConfigurationError.preferencesExportTimedOut
        }

        guard waitStatus == 0,
              fsync(outputDescriptor) == 0,
              let data = try? Data(contentsOf: outputURL), !data.isEmpty else {
            throw hasPreferencesFile ? UPicConfigurationError.unreadablePreferences : UPicConfigurationError.preferencesNotFound
        }
        return data
    }

    private static var hasPreferencesFile: Bool {
        defaultPreferencesURLs().contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func secureURL(_ rawValue: String?, field: String) throws -> URL {
        guard let value = nonempty(rawValue) else {
            throw UPicConfigurationError.incompleteS3Configuration("\(field) 为空")
        }
        let normalized = value.contains("://") ? value : "https://\(value)"
        guard let url = URL(string: normalized), url.scheme?.lowercased() == "https", url.host != nil else {
            throw UPicConfigurationError.incompleteS3Configuration("\(field) 必须是 HTTPS 地址")
        }
        return url
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func keyPrefix(from saveKeyPath: String) -> String {
        let templateMarkers = ["{filename}", "{uuid}", "{random}", "{md5}", "{sha256}"]
        let markerRange = templateMarkers.compactMap { saveKeyPath.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        let rawPrefix = markerRange.map { String(saveKeyPath[..<$0.lowerBound]) } ?? "uPic"
        let prefix = rawPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return prefix.isEmpty ? "uPic" : prefix
    }

    private static func inferredRegion(endpoint: URL) -> String {
        guard let host = endpoint.host?.lowercased() else { return "auto" }
        if host.contains("r2.cloudflarestorage.com") { return "auto" }
        let components = host.split(separator: ".")
        if let s3Index = components.firstIndex(of: "s3"), components.indices.contains(s3Index + 1),
           components[s3Index + 1] != "amazonaws" {
            return String(components[s3Index + 1])
        }
        return "us-east-1"
    }
}
