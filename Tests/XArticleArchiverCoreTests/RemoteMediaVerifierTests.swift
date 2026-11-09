import Foundation
import XCTest
@testable import XArticleArchiverCore

final class RemoteMediaVerifierTests: XCTestCase {
    private var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaResponseProtocol.self]
        return URLSession(configuration: config)
    }

    func testAcceptsRealImageAndMP4Prefixes() async throws {
        try await RemoteMediaVerifier.verify(URL(string: "https://media.example.test/image")!, session: session)
        try await RemoteMediaVerifier.verify(URL(string: "https://media.example.test/video")!, video: true, session: session)
    }

    func testRejectsDisguisedHTMLAndBrokenRangeAndTruncatedResponse() async {
        for path in ["html", "range", "truncated"] {
            do {
                try await RemoteMediaVerifier.verify(URL(string: "https://media.example.test/\(path)")!, session: session)
                XCTFail("Invalid media must be rejected: \(path)")
            } catch { }
        }
    }
}

private final class MediaResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        var data = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        var headers = ["Content-Type": "image/png"]
        var status = 200
        if path == "video" {
            data = Data([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d])
            headers["Content-Type"] = "video/mp4"
        } else if path == "html" { data = Data("<html>access denied</html>".utf8) }
        else if path == "range" { status = 206; headers["Content-Range"] = "bytes 1-8/100" }
        headers["Content-Length"] = path == "truncated" ? "100" : String(data.count)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
