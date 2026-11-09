import Foundation
import XCTest
@testable import XArticleArchiverCore

final class ReviewRegressionTests: XCTestCase {
    func testRetryMustPreserveManualMarkdownEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "markx-review-edits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ArchiveDatabase(url: root.appending(path: ".x-article-archiver/archive.sqlite"))
        let creator = Creator(xUserID: "review-writer", username: "writer", displayName: "作者")
        try await database.upsertCreator(creator)
        var document = CanonicalDocument(
            title: "保留手工笔记", authorName: creator.displayName, authorHandle: creator.username,
            contentType: .xArticle, sourceURL: URL(string: "https://x.com/writer/status/123")!,
            sourcePostID: "123", sourceArticleID: "review-123", publishedAt: Date(timeIntervalSince1970: 0),
            blocks: [CanonicalBlock(kind: .paragraph, text: "初始正文")], layoutFidelity: .renderedPageVerified
        )
        let pipeline = ArchivePipeline(database: database, imageHost: LocalMediaHostAdapter(archiveRoot: root))
        let original = try await pipeline.archive(document: document, creator: creator, root: root)
        let path = try XCTUnwrap(original.markdownPath)
        let edited = try String(contentsOfFile: path, encoding: .utf8) + "\n我的手工笔记，必须保留。\n"
        try edited.write(toFile: path, atomically: true, encoding: .utf8)
        document.blocks = [CanonicalBlock(kind: .paragraph, text: "更新后的来源正文")]
        do {
            _ = try await pipeline.archive(document: document, creator: creator, root: root)
            XCTFail("First refresh must refuse to overwrite edits")
        } catch ArchivePipelineError.localFileModified { }
        let afterFailure = try await database.article(sourcePostID: "123")
        XCTAssertEqual(afterFailure?.markdownPath, path, "Failed refresh must retain the old Markdown path")
        do {
            _ = try await pipeline.archive(document: document, creator: creator, root: root)
            XCTFail("Retry must also refuse to overwrite edits")
        } catch ArchivePipelineError.localFileModified { }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), edited, "Manual edits must survive a retry")
    }

    func testS3VerificationMustRejectAnEmptyImageResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewEmptyImageProtocol.self]
        let adapter = S3ImageHostAdapter(
            configuration: S3ImageHostConfiguration(
                endpoint: URL(string: "https://s3.example.test")!, bucket: "review",
                publicBaseURL: URL(string: "https://media.example.test")!
            ), accessKey: "synthetic-access", secretKey: "synthetic-secret",
            session: URLSession(configuration: configuration)
        )
        do {
            try await adapter.verify(remoteURL: URL(string: "https://media.example.test/empty.png")!)
            XCTFail("An empty response cannot prove that an image was uploaded correctly")
        } catch { }
    }
}

private final class ReviewEmptyImageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Content-Length": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
