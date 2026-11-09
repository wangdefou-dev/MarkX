import Foundation

/// Reads a bounded prefix even if a host ignores Range and sends a full video.
/// A successful status and MIME alone do not prove that media exists.
public enum RemoteMediaVerifier {
    public static func verify(_ url: URL, video: Bool = false, session: URLSession = .shared) async throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              !["localhost", "127.0.0.1", "::1"].contains(host) else {
            throw ImagePipelineError.insecureURL(url.absoluteString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https" else {
            throw ImagePipelineError.invalidHTTPStatus(0)
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw ImagePipelineError.invalidHTTPStatus(http.statusCode)
        }
        let mime = http.mimeType?.lowercased()
        guard mime?.hasPrefix(video ? "video/" : "image/") == true || mime == "application/octet-stream" else {
            throw ImagePipelineError.invalidMIME(mime)
        }
        var prefix = Data()
        for try await byte in bytes {
            prefix.append(byte)
            if prefix.count == 4096 { break }
        }
        guard !prefix.isEmpty else { throw ImagePipelineError.emptyFile }
        if http.expectedContentLength > 0,
           Int64(prefix.count) < min(4096, http.expectedContentLength) {
            throw ImagePipelineError.invalidOutput("媒体回读内容被截断")
        }
        if http.statusCode == 206 {
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  let endPart = range.split(separator: "/").first?.split(separator: "-").last,
                  range.lowercased().hasPrefix("bytes 0-"),
                  let end = Int(endPart), end >= 0, end < 4096,
                  prefix.count == end + 1 else {
                throw ImagePipelineError.invalidOutput("媒体 Range 回读范围不完整")
            }
        }
        let data = [UInt8](prefix)
        if video {
            guard data.count >= 12, String(bytes: data[4..<8], encoding: .ascii) == "ftyp" else {
                throw VideoPipelineError.invalidMP4
            }
        } else {
            let recognized = data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
                || data.starts(with: [0xff, 0xd8, 0xff])
                || data.starts(with: [0x47, 0x49, 0x46, 0x38])
                || (data.count >= 12 && String(bytes: data[0..<4], encoding: .ascii) == "RIFF"
                    && String(bytes: data[8..<12], encoding: .ascii) == "WEBP")
                || (data.count >= 16 && String(bytes: data[4..<8], encoding: .ascii) == "ftyp"
                    && ["avif", "avis"].contains(String(bytes: data[8..<12], encoding: .ascii) ?? ""))
            guard recognized else { throw ImagePipelineError.invalidMIME(mime) }
        }
    }
}
