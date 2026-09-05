import CryptoKit
import Foundation

public struct S3ImageHostConfiguration: Codable, Hashable, Sendable {
    public var endpoint: URL
    public var bucket: String
    public var publicBaseURL: URL
    public var region: String
    public var keyPrefix: String

    public init(endpoint: URL, bucket: String, publicBaseURL: URL, region: String = "auto", keyPrefix: String = "x-archive") {
        self.endpoint = endpoint
        self.bucket = bucket.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.publicBaseURL = publicBaseURL
        self.region = region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "auto" : region.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keyPrefix = keyPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }
}

public enum S3ImageHostError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case uploadFailed(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): "S3/R2 配置无效：\(detail)"
        case .uploadFailed(let code, let detail): "S3/R2 上传失败（HTTP \(code)）：\(detail)"
        }
    }
}

public struct S3ImageHostAdapter: ImageHostAdapter {
    public let displayName = "原生 S3 / Cloudflare R2"
    public var configuration: S3ImageHostConfiguration
    private var accessKey: String
    private var secretKey: String
    private let session: URLSession

    public init(configuration: S3ImageHostConfiguration, accessKey: String, secretKey: String, session: URLSession = .shared) {
        self.configuration = configuration
        self.accessKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public func probe() async -> ImageHostCapability {
        let valid = configuration.endpoint.scheme == "https"
            && configuration.endpoint.host != nil
            && configuration.publicBaseURL.scheme == "https"
            && configuration.publicBaseURL.host != nil
            && !accessKey.isEmpty
            && !secretKey.isEmpty
        return ImageHostCapability(
            name: displayName,
            version: "SigV4",
            isAvailable: valid,
            detail: valid ? "S3/R2 参数齐全，仍需执行测试上传" : "请填写 HTTPS endpoint、公开域名和访问密钥"
        )
    }

    public func upload(fileURLs: [URL]) async throws -> [UploadResult] {
        guard configuration.endpoint.scheme == "https", configuration.endpoint.host != nil else {
            throw S3ImageHostError.invalidConfiguration("Endpoint 必须是有效 HTTPS 地址")
        }
        guard configuration.publicBaseURL.scheme == "https", configuration.publicBaseURL.host != nil else {
            throw S3ImageHostError.invalidConfiguration("公开访问地址必须是有效 HTTPS 地址")
        }
        guard !accessKey.isEmpty, !secretKey.isEmpty else {
            throw S3ImageHostError.invalidConfiguration("Access Key 或 Secret Key 为空")
        }

        var output: [UploadResult] = []
        for fileURL in fileURLs {
            let fileHash = try hashFile(fileURL)
            let ext = fileURL.pathExtension.lowercased().isEmpty ? "bin" : fileURL.pathExtension.lowercased()
            let fileName = "\(fileHash).\(ext)"
            let keyParts = (configuration.keyPrefix.isEmpty ? [] : configuration.keyPrefix.split(separator: "/").map(String.init)) + [fileName]
            let uploadURL = objectURL(keyParts: keyParts, includeBucket: true)
            let publicURL = publicObjectURL(keyParts: keyParts)
            let payloadHash = fileHash
            try await retryingNetworkOperation {
                var request = URLRequest(url: uploadURL)
                request.httpMethod = "PUT"
                request.timeoutInterval = 120
                request.setValue(contentType(forExtension: ext), forHTTPHeaderField: "Content-Type")
                sign(&request, payloadHash: payloadHash, date: Date())
                let (_, response) = try await session.upload(for: request, fromFile: fileURL)
                guard let http = response as? HTTPURLResponse else {
                    throw S3ImageHostError.uploadFailed(0, "没有收到 HTTP 响应")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw S3ImageHostError.uploadFailed(http.statusCode, "请检查 endpoint、bucket、region 和密钥权限")
                }
            }
            output.append(UploadResult(localPath: fileURL.path, remoteURL: publicURL))
        }
        return output
    }

    public func verify(remoteURL: URL) async throws {
        guard remoteURL.scheme == "https", let host = remoteURL.host, !host.isEmpty,
              host != "localhost", host != "127.0.0.1", host != "::1" else {
            throw ImagePipelineError.insecureURL(remoteURL.absoluteString)
        }
        try await retryingNetworkOperation(attempts: 4) {
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
    }

    private func retryingNetworkOperation(
        attempts: Int = 3,
        operation: () async throws -> Void
    ) async throws {
        precondition(attempts > 0)
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                try await operation()
                return
            } catch {
                guard attempt + 1 < attempts else { throw error }
                let delay = attempt == 0 ? 500 : min(2_500, 900 * (attempt + 1))
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    public func signedRequestForTesting(fileURL: URL, date: Date) throws -> URLRequest {
        let hash = try hashFile(fileURL)
        let ext = fileURL.pathExtension.lowercased().isEmpty ? "bin" : fileURL.pathExtension.lowercased()
        let keyParts = (configuration.keyPrefix.isEmpty ? [] : configuration.keyPrefix.split(separator: "/").map(String.init)) + ["\(hash).\(ext)"]
        var request = URLRequest(url: objectURL(keyParts: keyParts, includeBucket: true))
        request.httpMethod = "PUT"
        request.setValue(contentType(forExtension: ext), forHTTPHeaderField: "Content-Type")
        sign(&request, payloadHash: hash, date: date)
        return request
    }

    private func objectURL(keyParts: [String], includeBucket: Bool) -> URL {
        var url = configuration.endpoint
        if includeBucket, !configuration.bucket.isEmpty { url.append(path: configuration.bucket) }
        for part in keyParts { url.append(path: part) }
        return url
    }

    private func publicObjectURL(keyParts: [String]) -> URL {
        var url = configuration.publicBaseURL
        for part in keyParts { url.append(path: part) }
        return url
    }

    private func sign(_ request: inout URLRequest, payloadHash: String, date: Date) {
        guard let url = request.url else { return }
        let timestamp = Self.timestampFormatter.string(from: date)
        let dateStamp = String(timestamp.prefix(8))
        let host = url.port.map { "\(url.host!):\($0)" } ?? url.host!
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let canonicalURI = encodedPath.isEmpty ? "/" : encodedPath
        let canonicalQuery = url.query ?? ""
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(timestamp)\n"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = "\(request.httpMethod ?? "PUT")\n\(canonicalURI)\n\(canonicalQuery)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let scope = "\(dateStamp)/\(configuration.region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(ContentHasher.sha256(canonicalRequest))"
        let signingKey = signatureKey(secret: secretKey, date: dateStamp, region: configuration.region, service: "s3")
        let signature = hmac(key: signingKey, data: Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private func signatureKey(secret: String, date: String, region: String, service: String) -> Data {
        let dateKey = hmac(key: Data("AWS4\(secret)".utf8), data: Data(date.utf8))
        let regionKey = hmac(key: dateKey, data: Data(region.utf8))
        let serviceKey = hmac(key: regionKey, data: Data(service.utf8))
        return hmac(key: serviceKey, data: Data("aws4_request".utf8))
    }

    private func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
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

    private func contentType(forExtension ext: String) -> String {
        switch ext {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "avif": "image/avif"
        case "mp4", "m4v": "video/mp4"
        default: "application/octet-stream"
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}
