import Foundation
import CommonCrypto
import CryptoKit
import XCTest
@testable import XArticleArchiverCore

final class HandleParserTests: XCTestCase {
    func testParsesHandlesAndURLsWithoutDuplicates() {
        let input = """
        @OpenAI
        https://x.com/XDevelopers/status/123
        openai
        invalid/name
        """
        XCTAssertEqual(HandleParser.parse(input), ["OpenAI", "XDevelopers"])
    }

    func testRejectsUnsafeOrTooLongHandles() {
        XCTAssertNil(HandleParser.normalize("../etc/passwd"))
        XCTAssertNil(HandleParser.normalize("abcdefghijklmnop"))
        XCTAssertNil(HandleParser.normalize("hello-world"))
    }

    func testSingleCreatorInputRejectsReturnAndKeepsFirstNonemptyPastedLine() {
        XCTAssertEqual(
            SingleCreatorInputPolicy.sanitize("@OpenAI\n@XDevelopers"),
            "@OpenAI"
        )
        XCTAssertEqual(
            SingleCreatorInputPolicy.sanitize("\r\n  https://x.com/OpenAI  \r\n@XDevelopers"),
            "https://x.com/OpenAI"
        )
        XCTAssertEqual(
            SingleCreatorInputPolicy.sanitize("@OpenAI\u{2028}@XDevelopers"),
            "@OpenAI"
        )
    }

    func testSingleCreatorInputPreservesAnUnfinishedSingleLineExactly() {
        XCTAssertEqual(SingleCreatorInputPolicy.sanitize("  @Open"), "  @Open")
        XCTAssertEqual(SingleCreatorInputPolicy.sanitize("https://x.com/"), "https://x.com/")
    }
}

final class XAPICostEstimatorTests: XCTestCase {
    func testCalculatesAConservativePaidScanUpperBound() {
        XCTAssertEqual(
            XAPICostEstimator.maximumCostUSD(
                postReadLimit: 50,
                creatorCount: 1,
                userLookupCount: 1
            ),
            0.26,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            XAPICostEstimator.maximumCostUSD(
                postReadLimit: 50,
                creatorCount: 2,
                userLookupCount: 2
            ),
            0.52,
            accuracy: 0.000_001
        )
    }

    func testPostReadProgressCostNeverBecomesNegative() {
        XCTAssertEqual(XAPICostEstimator.postReadCostUSD(300), 1.50, accuracy: 0.000_001)
        XCTAssertEqual(XAPICostEstimator.postReadCostUSD(-1), 0, accuracy: 0.000_001)
    }
}

final class XArticleURLParserTests: XCTestCase {
    func testParsesMultipleStatusLinksDeduplicatesAndPreservesInputOrder() {
        let input = """
        https://x.com/first_writer/status/2091770029713084630?s=20
        twitter.com/second_writer/status/1999999999999999999#article
        https://x.com/duplicate/status/2091770029713084630
        https://example.com/writer/status/1888888888888888888
        https://x.com/writer
        """
        let links = XArticleURLParser.parse(input)
        XCTAssertEqual(links.map(\.postID), ["2091770029713084630", "1999999999999999999"])
        XCTAssertEqual(links.map(\.username), ["first_writer", "second_writer"])
    }

    func testParsesDedicatedArticleRoutesIncludingGenericIRoute() {
        let links = XArticleURLParser.parse("""
        https://x.com/first_writer/article/2091770029713084630
        https://x.com/i/article/1999999999999999999
        """)
        XCTAssertEqual(links.map(\.postID), ["2091770029713084630", "1999999999999999999"])
        XCTAssertEqual(links.map(\.username), ["first_writer", "i"])
    }

    func testRejectsInsecureMalformedAndNonNumericLinks() {
        let input = """
        http://x.com/writer/status/123
        https://x.com/writer/status/not-an-id
        https://x.com/i/article/not-an-id
        """
        XCTAssertTrue(XArticleURLParser.parse(input).isEmpty)
    }

    func testCreatorArticlesPageParserKeepsOnlyExactOwnerStatusRoutes() {
        let links = XArticleURLParser.parseCreatorArticlesPageLinks(
            [
                "https://x.com/example/status/2091770029713084630",
                "https://x.com/example/status/2091770029713084630/analytics",
                "https://x.com/other/status/1999999999999999999",
                "https://x.com/example/article/1888888888888888888",
                "https://x.com/example/status/1777777777777777777?ref=articles"
            ],
            expectedUsername: "@Example"
        )
        XCTAssertEqual(
            links.map(\.postID),
            ["2091770029713084630", "1777777777777777777"]
        )
        XCTAssertTrue(links.allSatisfy { $0.username.caseInsensitiveCompare("example") == .orderedSame })
    }

    func testDerivesSourcePublishTimeFromSnowflakeInsteadOfArchiveTime() throws {
        let publishedAt = try XCTUnwrap(
            XArticleURLParser.publishedAt(forPostID: "2083898984926720291")
        )
        XCTAssertEqual(publishedAt.timeIntervalSince1970, 1_785_675_209.634, accuracy: 0.001)
        XCTAssertNil(XArticleURLParser.publishedAt(forPostID: "not-a-post-id"))
    }
}

final class ArchiveDirectorySynchronizerTests: XCTestCase {
    func testCopiesHiddenDatabaseNestedArticlesAndReusesVerifiedFiles() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "archive-directory-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = workspace.appending(path: "source", directoryHint: .isDirectory)
        let destination = workspace.appending(path: "destination", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let databaseDirectory = source.appending(path: ".x-article-archiver", directoryHint: .isDirectory)
        let assetDirectory = databaseDirectory.appending(path: "assets-cache", directoryHint: .isDirectory)
        let creatorDirectory = source.appending(path: "@writer", directoryHint: .isDirectory)
        let articleDirectory = source.appending(path: "@writer/articles", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        try Data("database".utf8).write(to: databaseDirectory.appending(path: "archive.sqlite"))
        try Data("ignored-wal".utf8).write(to: databaseDirectory.appending(path: "archive.sqlite-wal"))
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: assetDirectory.appending(path: "image.jpg"))
        try FileManager.default.createDirectory(at: creatorDirectory, withIntermediateDirectories: true)
        try Data().write(to: creatorDirectory.appending(path: ".DS_Store"))
        try FileManager.default.createDirectory(at: articleDirectory, withIntermediateDirectories: true)
        try Data("# article".utf8).write(to: articleDirectory.appending(path: "article.md"))

        let first = try ArchiveDirectorySynchronizer.synchronize(from: source, to: destination)
        XCTAssertEqual(first.copiedFileCount, 3)
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "@writer/articles/article.md"), encoding: .utf8),
            "# article"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: ".x-article-archiver/assets-cache/image.jpg"), encoding: .utf8),
            "image"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appending(path: ".x-article-archiver/archive.sqlite-wal").path
        ))

        let second = try ArchiveDirectorySynchronizer.synchronize(from: source, to: destination)
        XCTAssertEqual(second.copiedFileCount, 0)
        XCTAssertEqual(second.reusedFileCount, 3)
        XCTAssertEqual(
            ArchiveDirectorySynchronizer.rebasedPath(
                source.appending(path: "@writer/articles/article.md").path,
                from: source,
                to: destination
            ),
            destination.appending(path: "@writer/articles/article.md").path
        )
        XCTAssertEqual(
            ArchiveDirectorySynchronizer.relativePath(
                for: source.appending(path: "@writer/articles/article.md").path,
                under: source
            ),
            "@writer/articles/article.md"
        )
    }

    func testRefusesDifferentDestinationFileWithoutOverwritingIt() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "archive-directory-conflict-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = workspace.appending(path: "source", directoryHint: .isDirectory)
        let destination = workspace.appending(path: "destination", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source.appending(path: "index.md"))
        try Data("destination".utf8).write(to: destination.appending(path: "index.md"))

        XCTAssertThrowsError(try ArchiveDirectorySynchronizer.synchronize(from: source, to: destination))
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "index.md"), encoding: .utf8),
            "destination"
        )
    }

    func testReplacesOnlyAnExplicitlyApprovedRetryFile() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "archive-directory-retry-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = workspace.appending(path: "source", directoryHint: .isDirectory)
        let destination = workspace.appending(path: "destination", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("current-database".utf8).write(to: source.appending(path: "archive.sqlite"))
        try Data("retry-database".utf8).write(to: destination.appending(path: "archive.sqlite"))

        let result = try ArchiveDirectorySynchronizer.synchronize(
            from: source,
            to: destination,
            replaceableRelativePaths: ["archive.sqlite"]
        )

        XCTAssertEqual(result.copiedFileCount, 1)
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "archive.sqlite"), encoding: .utf8),
            "current-database"
        )
    }
}

final class ChromeXSessionReaderTests: XCTestCase {
    func testDecryptsChromeV24CookieAndRejectsAHostMismatch() throws {
        let password = Data("unit-test-safe-storage".utf8)
        let host = ".x.com"
        let expected = "local-cookie-value"
        var cleartext = Data(SHA256.hash(data: Data(host.utf8)))
        cleartext.append(Data(expected.utf8))
        let encrypted = try chromeV10Encrypted(cleartext, password: password)

        XCTAssertEqual(
            try ChromeXSessionReader.decryptCookieValue(
                encrypted,
                host: host,
                password: password,
                databaseVersion: 24
            ),
            expected
        )
        XCTAssertThrowsError(try ChromeXSessionReader.decryptCookieValue(
            encrypted,
            host: ".twitter.com",
            password: password,
            databaseVersion: 24
        ))
    }

    func testReadsLiveChromeXSessionWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["RUN_CHROME_SESSION_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_CHROME_SESSION_INTEGRATION=1 to verify the local Chrome X session without printing cookie values")
        }
        let session = try ChromeXSessionReader.readActiveSession()
        XCTAssertFalse(session.profileName.isEmpty)
        XCTAssertTrue(session.cookies.contains { $0.name == "auth_token" && $0.domain.contains("x.com") })
        XCTAssertTrue(session.cookies.allSatisfy {
            ["x.com", ".x.com", "twitter.com", ".twitter.com"].contains($0.domain)
        })
    }

    private func chromeV10Encrypted(_ plaintext: Data, password: Data) throws -> Data {
        let salt = Data("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derivationStatus = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress,
                    password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    &key,
                    key.count
                )
            }
        }
        guard derivationStatus == kCCSuccess else { throw ChromeXSessionError.decryptionFailed }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = plaintext.withUnsafeBytes { bytes in
            CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                key,
                key.count,
                iv,
                bytes.baseAddress,
                plaintext.count,
                &output,
                output.count,
                &outputLength
            )
        }
        guard status == kCCSuccess else { throw ChromeXSessionError.decryptionFailed }
        var result = Data("v10".utf8)
        result.append(contentsOf: output.prefix(outputLength))
        return result
    }
}

final class SafeFileNameTests: XCTestCase {
    func testSanitizesTraversalAndReservedCharacters() {
        let value = SafeFileName.sanitize("../危险/标题: \"测试\"\n下一行")
        XCTAssertFalse(value.contains("/"))
        XCTAssertFalse(value.contains(".."))
        XCTAssertFalse(value.contains("\n"))
        XCTAssertTrue(value.contains("危险"))
    }

    func testStableIDDisambiguatesDuplicateTitles() {
        let date = Date(timeIntervalSince1970: 0)
        let first = SafeFileName.articleFileName(title: "同名", publishedAt: date, postID: "123456789")
        let second = SafeFileName.articleFileName(title: "同名", publishedAt: date, postID: "987654321")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasSuffix("23456789.md"))
    }
}

final class MarkdownRendererTests: XCTestCase {
    func testRendersStructuredDocumentAndRemoteImage() throws {
        let remote = URL(string: "https://images.example.test/a.png")!
        let document = CanonicalDocument(
            title: "标题：\"安全\"",
            authorName: "作者",
            authorHandle: "writer",
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/123")!,
            sourcePostID: "123",
            publishedAt: Date(timeIntervalSince1970: 0),
            blocks: [
                CanonicalBlock(kind: .paragraph, text: "第一段"),
                CanonicalBlock(kind: .heading, text: "小标题", level: 1),
                CanonicalBlock(kind: .unorderedListItem, text: "列表项"),
                CanonicalBlock(kind: .quote, text: "引用"),
                CanonicalBlock(kind: .image, mediaID: "m1")
            ],
            media: [MediaAsset(id: "m1", sourceURL: URL(string: "https://pbs.twimg.com/a.png")!, altText: "说明", position: 0, remoteURL: remote)]
        )
        let markdown = try MarkdownRenderer.render(document: document, archivedAt: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(markdown.contains("title: \"标题：\\\"安全\\\"\""))
        XCTAssertTrue(markdown.contains("# 标题：\"安全\""))
        XCTAssertTrue(markdown.contains("## 小标题"))
        XCTAssertTrue(markdown.contains("- 列表项"))
        XCTAssertTrue(markdown.contains("> 引用"))
        XCTAssertTrue(markdown.contains("![说明](https://images.example.test/a.png)"))
        try MarkdownRenderer.validateRenderedText(document: document, markdown: markdown)
    }

    func testNumbersOrderedListsPreservesNestingAndSeparatesFollowingParagraph() throws {
        let blocks = [
            CanonicalBlock(kind: .orderedListItem, text: "第一项", sourceEntityType: "ordered-marker:1."),
            CanonicalBlock(kind: .orderedListItem, text: "第二项", sourceEntityType: "ordered-marker:1."),
            CanonicalBlock(kind: .orderedListItem, text: "子项一", depth: 1),
            CanonicalBlock(kind: .orderedListItem, text: "子项二", depth: 1),
            CanonicalBlock(kind: .orderedListItem, text: "第三项"),
            CanonicalBlock(kind: .paragraph, text: "列表后的正文"),
            CanonicalBlock(kind: .unorderedListItem, text: "圆点项"),
            CanonicalBlock(kind: .unorderedListItem, text: "嵌套圆点项", depth: 1),
            CanonicalBlock(kind: .paragraph, text: "无序列表后的正文")
        ]
        let document = CanonicalDocument(
            title: "列表排版",
            authorName: "作者",
            authorHandle: "writer",
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/123")!,
            sourcePostID: "123",
            publishedAt: Date(timeIntervalSince1970: 0),
            blocks: blocks
        )

        XCTAssertEqual(
            ArticleListMarkerResolver.orderedMarkers(for: blocks),
            ["1.", "2.", "1.", "2.", "3.", nil, nil, nil, nil]
        )
        let markdown = try MarkdownRenderer.render(document: document)
        XCTAssertTrue(markdown.contains(
            "1. 第一项\n2. 第二项\n    1. 子项一\n    2. 子项二\n3. 第三项\n\n列表后的正文"
        ))
        XCTAssertTrue(markdown.contains(
            "- 圆点项\n    - 嵌套圆点项\n\n无序列表后的正文"
        ))
        try MarkdownRenderer.validateRenderedText(document: document, markdown: markdown)
    }

    func testExportChecksumDetectsManualEditsAndSurvivesFormattingUpgrade() throws {
        let document = CanonicalDocument(
            title: "校验",
            authorName: "作者",
            authorHandle: "writer",
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/123")!,
            sourcePostID: "123",
            publishedAt: Date(timeIntervalSince1970: 0),
            blocks: [CanonicalBlock(kind: .paragraph, text: "正文")]
        )
        let rendered = try MarkdownRenderer.render(document: document)
        let exported = MarkdownRenderer.addingExportChecksum(to: rendered)

        XCTAssertTrue(exported.contains("exporter_version: \"0.2\"\nexport_checksum:"))
        XCTAssertTrue(MarkdownRenderer.isUnmodifiedExport(exported))
        XCTAssertFalse(MarkdownRenderer.isUnmodifiedExport(exported + "手工修改"))
    }

    func testRefusesImageWithoutUploadedURL() {
        let document = CanonicalDocument(
            title: "标题",
            authorName: "作者",
            authorHandle: "writer",
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/123")!,
            sourcePostID: "123",
            publishedAt: Date(),
            blocks: [CanonicalBlock(kind: .paragraph, text: "正文"), CanonicalBlock(kind: .image, mediaID: "m1")],
            media: [MediaAsset(id: "m1", sourceURL: URL(string: "https://pbs.twimg.com/a.png")!, position: 0)]
        )
        XCTAssertThrowsError(try MarkdownRenderer.render(document: document))
    }

    func testRejectsMissingDuplicateParagraphEvenWhenSameTextStillExists() throws {
        let document = CanonicalDocument(
            title: "重复段落校验",
            authorName: "作者",
            authorHandle: "writer",
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/123")!,
            sourcePostID: "123",
            publishedAt: Date(timeIntervalSince1970: 0),
            blocks: [
                CanonicalBlock(kind: .paragraph, text: "相同内容"),
                CanonicalBlock(kind: .paragraph, text: "相同内容"),
                CanonicalBlock(kind: .paragraph, text: "结尾")
            ]
        )
        let markdown = try MarkdownRenderer.render(document: document)
        let damaged = markdown.replacingOccurrences(of: "相同内容\n\n相同内容", with: "相同内容")
        XCTAssertThrowsError(try MarkdownRenderer.validateRenderedText(document: document, markdown: damaged))
    }

    func testRejectsImageURLsWhenTheirBodyOrderIsSwapped() throws {
        let firstURL = "https://images.example.test/first.png"
        let secondURL = "https://images.example.test/second.png"
        let document = CanonicalDocument(
            title: "图片顺序校验",
            authorName: "作者",
            authorHandle: "writer",
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/123")!,
            sourcePostID: "123",
            publishedAt: Date(timeIntervalSince1970: 0),
            blocks: [
                CanonicalBlock(kind: .image, mediaID: "m1"),
                CanonicalBlock(kind: .paragraph, text: "中间正文"),
                CanonicalBlock(kind: .image, mediaID: "m2")
            ],
            media: [
                MediaAsset(id: "m1", sourceURL: URL(string: "https://pbs.twimg.com/first.png")!, position: 0, remoteURL: URL(string: firstURL)),
                MediaAsset(id: "m2", sourceURL: URL(string: "https://pbs.twimg.com/second.png")!, position: 1, remoteURL: URL(string: secondURL))
            ],
            sourceMediaIDs: ["m1", "m2"],
            layoutFidelity: .exactStructure
        )
        let markdown = try MarkdownRenderer.render(document: document)
        let swapped = markdown
            .replacingOccurrences(of: firstURL, with: "https://images.example.test/temporary.png")
            .replacingOccurrences(of: secondURL, with: firstURL)
            .replacingOccurrences(of: "https://images.example.test/temporary.png", with: secondURL)
        XCTAssertThrowsError(try MarkdownRenderer.validateRenderedText(document: document, markdown: swapped))
    }

    func testRendersInlineStylesLinksAndLiteralMarkdownCharacters() throws {
        let text = "粗体 链接 #不是标题"
        let document = CanonicalDocument(
            title: "富文本",
            authorName: "作者",
            authorHandle: "writer",
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/123")!,
            sourcePostID: "123",
            publishedAt: Date(timeIntervalSince1970: 0),
            blocks: [CanonicalBlock(
                kind: .paragraph,
                text: text,
                inlineStyles: [InlineStyleRange(offset: 0, length: 2, style: .bold)],
                links: [LinkRange(offset: 3, length: 2, url: URL(string: "https://example.test/read")!)]
            )]
        )
        let markdown = try MarkdownRenderer.render(document: document)
        XCTAssertTrue(markdown.contains("**粗体**"))
        XCTAssertTrue(markdown.contains("[链接](https://example.test/read)"))
        XCTAssertTrue(markdown.contains("\\#不是标题"))
        try MarkdownRenderer.validateRenderedText(document: document, markdown: markdown)
    }
}

final class XContentDecoderTests: XCTestCase {
    func testDecodesDraftJSArticleAndMedia() throws {
        let json = """
        {
          "id":"1900000000000000001",
          "created_at":"2026-09-04T08:00:00Z",
          "attachments":{"media_keys":["m1"]},
          "article":{
            "id":"article-1",
            "title":"一篇测试长文",
            "content_state":{
              "blocks":[
                {"type":"header-one","text":"第一节","depth":0,"inlineStyleRanges":[],"entityRanges":[]},
                {"type":"unstyled","text":"这是正文。","depth":0,"inlineStyleRanges":[],"entityRanges":[]}
              ],
              "entityMap":{}
            }
          }
        }
        """
        let post = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let includesJSON = """
        {"media":[{"type":"photo","media_key":"m1","url":"https://pbs.twimg.com/media/test.png","alt_text":"测试图片"}]}
        """
        let includes = try JSONDecoder().decode(JSONValue.self, from: Data(includesJSON.utf8))
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        let document = try XCTUnwrap(XContentDecoder.decode(RawPostEnvelope(post: post, includes: includes), creator: creator))
        XCTAssertEqual(document.title, "一篇测试长文")
        XCTAssertEqual(document.blocks.first?.kind, .heading)
        XCTAssertEqual(document.media.count, 1)
        XCTAssertEqual(document.blocks.last?.mediaID, "m1")
    }

    func testIgnoresOrdinaryShortPost() throws {
        let post = try JSONDecoder().decode(JSONValue.self, from: Data("{\"id\":\"1\",\"text\":\"hello\"}".utf8))
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        XCTAssertNil(try XContentDecoder.decode(RawPostEnvelope(post: post), creator: creator))
    }

    func testIgnoresNotePostEvenWhenItHasLongTextAndMedia() throws {
        let post = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"10","attachments":{"media_keys":["m-own"]},"note_tweet":{"text":"这是一条长帖正文"}}
        """.utf8))
        let includes = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"media":[
          {"type":"photo","media_key":"m-own","url":"https://pbs.twimg.com/media/own.png"},
          {"type":"photo","media_key":"m-other","url":"https://pbs.twimg.com/media/other.png"}
        ]}
        """.utf8))
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        XCTAssertNil(try XContentDecoder.decode(RawPostEnvelope(post: post, includes: includes), creator: creator))
    }

    func testDecodesCurrentXArticlePlainTextAndEveryDeclaredImage() throws {
        let post = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {
          "id":"2091770029713084630",
          "created_at":"2026-09-04T08:00:00Z",
          "text":"https://t.co/only-the-entry-post",
          "article":{
            "title":"完整 X Article",
            "plain_text":"第一段\\n \\n第二段\\n1、第一个步骤",
            "cover_media":"m-cover",
            "media_entities":["m-body"],
            "entities":{"code":[{"code":"print(1)","language":"plaintext"}]}
          }
        }
        """.utf8))
        let includes = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"media":[
          {"type":"photo","media_key":"m-cover","url":"https://pbs.twimg.com/media/cover.jpg"},
          {"type":"photo","media_key":"m-body","url":"https://pbs.twimg.com/media/body.jpg"},
          {"type":"photo","media_key":"m-other","url":"https://pbs.twimg.com/media/other.jpg"}
        ]}
        """.utf8))
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        var document = try XCTUnwrap(XContentDecoder.decode(RawPostEnvelope(post: post, includes: includes), creator: creator))

        XCTAssertEqual(document.contentType, .xArticle)
        XCTAssertEqual(document.title, "完整 X Article")
        XCTAssertEqual(document.media.map(\.id), ["m-cover", "m-body"])
        XCTAssertEqual(document.blocks.first?.sourceEntityType, "article-cover")
        XCTAssertTrue(document.blocks.contains { $0.kind == .paragraph && $0.text == "第一段" })
        XCTAssertTrue(document.blocks.contains { $0.kind == .paragraph && $0.text == "第二段" })
        XCTAssertTrue(document.blocks.contains { $0.kind == .orderedListItem && $0.text == "第一个步骤" })
        XCTAssertTrue(document.blocks.contains { $0.kind == .code && $0.text == "print(1)" })
        XCTAssertFalse(document.blocks.contains { $0.text.contains("only-the-entry-post") })
        XCTAssertEqual(document.blocks.filter { $0.kind == .image }.count, 2)
        XCTAssertTrue(document.blocks.contains { $0.kind == .blankLine })
        XCTAssertEqual(document.layoutFidelity, .textAndMediaOnly)
        XCTAssertEqual(document.sourceMediaIDs, ["m-cover", "m-body"])
        try ContentFidelityValidator.validateCanonical(document)

        for index in document.media.indices {
            document.media[index].remoteURL = URL(string: "https://images.example.test/\(document.media[index].id).jpg")
        }
        let markdown = try MarkdownRenderer.render(document: document)
        XCTAssertTrue(markdown.contains("第一段"))
        XCTAssertTrue(markdown.contains("第二段"))
        XCTAssertTrue(markdown.contains("print(1)"))
        XCTAssertEqual(markdown.components(separatedBy: "![").count - 1, 2)
        try MarkdownRenderer.validateRenderedText(document: document, markdown: markdown)
    }

    func testPlainTextFidelityGateRejectsChangedTextOrLineStructure() throws {
        let post = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {
          "id":"200",
          "article":{
            "title":"完整性测试",
            "plain_text":"第一段\\n\\n第二段\\n1、列表项"
          }
        }
        """.utf8))
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        var document = try XCTUnwrap(XContentDecoder.decode(RawPostEnvelope(post: post), creator: creator))
        try ContentFidelityValidator.validateCanonical(document)
        let paragraphIndex = try XCTUnwrap(document.blocks.firstIndex { $0.text == "第二段" })
        document.blocks[paragraphIndex].text = "第二段被改坏"
        XCTAssertThrowsError(try ContentFidelityValidator.validateCanonical(document))
    }

    func testMarksDraftJSWithAnchoredImageAsExactStructure() throws {
        let post = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {
          "id":"201",
          "article":{
            "title":"结构完整",
            "media_entities":["m1"],
            "content_state":{
              "blocks":[
                {"type":"unstyled","text":"正文","inlineStyleRanges":[{"offset":0,"length":2,"style":"BOLD"}],"entityRanges":[]},
                {"type":"atomic","text":"","inlineStyleRanges":[],"entityRanges":[{"offset":0,"length":1,"key":"0"}]}
              ],
              "entityMap":{"0":{"type":"image","data":{"media_id":"m1"}}}
            }
          }
        }
        """.utf8))
        let includes = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"media":[{"type":"photo","media_key":"m1","url":"https://pbs.twimg.com/media/one.png"}]}
        """.utf8))
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        let document = try XCTUnwrap(XContentDecoder.decode(RawPostEnvelope(post: post, includes: includes), creator: creator))
        XCTAssertEqual(document.layoutFidelity, .exactStructure)
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph, .image])
        try ContentFidelityValidator.validateCanonical(document)
    }

    func testRejectsArticleWhenDeclaredImageIsMissingFromIncludes() throws {
        let post = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {
          "id":"202",
          "article":{
            "title":"不能静默漏图",
            "plain_text":"正文",
            "cover_media":"m-cover",
            "media_entities":["m-missing"]
          }
        }
        """.utf8))
        let includes = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"media":[{"type":"photo","media_key":"m-cover","url":"https://pbs.twimg.com/media/cover.png"}]}
        """.utf8))
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        XCTAssertThrowsError(try XContentDecoder.decode(RawPostEnvelope(post: post, includes: includes), creator: creator)) { error in
            XCTAssertTrue(error.localizedDescription.contains("m-missing"))
        }
    }

    func testLiveResponseFixtureWhenExplicitlyProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["X_ARTICLE_RESPONSE_FIXTURE"] else {
            throw XCTSkip("Set X_ARTICLE_RESPONSE_FIXTURE to a freshly fetched official X API response")
        }
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let post = try XCTUnwrap(root["data"])
        let creator = Creator(xUserID: "live-user", username: "wangdefou", displayName: "得否")
        let document = try XCTUnwrap(XContentDecoder.decode(
            RawPostEnvelope(post: post, includes: root["includes"]),
            creator: creator
        ))
        let visibleText = document.blocks
            .filter { $0.kind != .image && $0.kind != .divider }
            .map(\.text)
            .joined(separator: "\n")

        XCTAssertEqual(document.contentType, .xArticle)
        XCTAssertGreaterThan(visibleText.count, 500)
        XCTAssertFalse(visibleText.hasPrefix("https://t.co/"))
        XCTAssertGreaterThan(document.media.count, 0)
        XCTAssertEqual(document.blocks.filter { $0.kind == .image }.count, document.media.count)
        XCTAssertEqual(document.sourcePlainText, root["data"]?["article"]?["plain_text"]?.stringValue)
        XCTAssertEqual(document.sourceMediaIDs, document.media.map(\.id))
        try ContentFidelityValidator.validateCanonical(document)
    }

    func testAssemblesLongSelfReplyThreadAndKeepsPerPostMedia() throws {
        let repeated = String(repeating: "这是线程正文，", count: 40)
        let raw = """
        [
          {"id":"100","author_id":"u1","conversation_id":"100","created_at":"2026-09-04T08:00:00Z","text":"\(repeated)","attachments":{"media_keys":["m1"]}},
          {"id":"101","author_id":"u1","conversation_id":"100","created_at":"2026-09-04T08:01:00Z","text":"\(repeated)","referenced_tweets":[{"type":"replied_to","id":"100"}],"attachments":{"media_keys":["m2"]}}
        ]
        """
        let posts = try JSONDecoder().decode([JSONValue].self, from: Data(raw.utf8))
        let includes = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"media":[
          {"type":"photo","media_key":"m1","url":"https://pbs.twimg.com/media/one.png"},
          {"type":"photo","media_key":"m2","url":"https://pbs.twimg.com/media/two.png"},
          {"type":"photo","media_key":"m3","url":"https://pbs.twimg.com/media/unrelated.png"}
        ]}
        """.utf8))
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        let documents = XContentDecoder.decodeThreads(posts: posts, includes: includes, creator: creator)
        let document = try XCTUnwrap(documents.first)
        XCTAssertEqual(document.contentType, .thread)
        XCTAssertEqual(document.sourcePostID, "100")
        XCTAssertEqual(document.media.map(\.id), ["m1", "m2"])
        XCTAssertEqual(document.blocks.filter { $0.kind == .divider }.count, 1)
    }
}

final class BrowserArticleCaptureDecoderTests: XCTestCase {
    private let link = XArticleLink(
        postID: "2094984812251746424",
        username: "writer",
        originalURL: URL(string: "https://x.com/writer/status/2094984812251746424")!
    )

    func testPreservesRenderedBlockOrderStylesCodeAndOriginalImages() throws {
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        let payload = BrowserArticleCapturePayload(
            postID: link.postID,
            title: "完整排版",
            authorHandle: "writer",
            authorName: "作者",
            publishedAt: "2026-09-02T03:04:00.000Z",
            pageURL: link.originalURL.absoluteString,
            blocks: [
                BrowserCapturedBlock(
                    kind: .image,
                    imageURL: "https://pbs.twimg.com/media/cover?format=jpg&name=medium",
                    imageID: "cover",
                    altText: "封面"
                ),
                BrowserCapturedBlock(
                    kind: .paragraph,
                    text: "第一段链接",
                    styles: [InlineStyleRange(offset: 0, length: 3, style: .bold)],
                    links: [BrowserCapturedLink(offset: 3, length: 2, url: "https://example.test")]
                ),
                BrowserCapturedBlock(kind: .heading, text: "第一节", level: 1),
                BrowserCapturedBlock(kind: .unorderedListItem, text: "列表项"),
                BrowserCapturedBlock(kind: .orderedListItem, text: "第三项", listMarker: "3."),
                BrowserCapturedBlock(
                    kind: .table,
                    text: "阶段\n形态\n验证\nOPC",
                    tableRows: [
                        [
                            BrowserCapturedTableCell(text: "阶段", isHeader: true),
                            BrowserCapturedTableCell(text: "形态", isHeader: true)
                        ],
                        [
                            BrowserCapturedTableCell(text: "验证"),
                            BrowserCapturedTableCell(
                                text: "OPC",
                                styles: [InlineStyleRange(offset: 0, length: 3, style: .bold)]
                            )
                        ]
                    ]
                ),
                BrowserCapturedBlock(kind: .code, text: "print(1)", language: "python"),
                BrowserCapturedBlock(
                    kind: .image,
                    imageURL: "https://pbs.twimg.com/media/body?format=png&name=small",
                    imageID: "body"
                )
            ]
        )
        let context = BrowserArticleCaptureContext(
            link: link,
            creator: creator,
            publishedAt: Date(timeIntervalSince1970: 123),
            sourceArticleID: "article-1",
            expectedPlainText: "第一段链接\n第一节\n• 列表项\n3. 第三项\n阶段\n形态\n验证\nOPC"
        )

        var document = try BrowserArticleCaptureDecoder.decode(payload, context: context)
        XCTAssertEqual(document.publishedAt.timeIntervalSince1970, 1_788_318_240, accuracy: 0.001)
        XCTAssertEqual(document.layoutFidelity, .renderedPageVerified)
        XCTAssertEqual(document.blocks.map(\.kind), [.image, .paragraph, .heading, .unorderedListItem, .orderedListItem, .table, .code, .image])
        XCTAssertEqual(document.media.map(\.id), ["cover", "body"])
        XCTAssertTrue(document.media.allSatisfy { $0.sourceURL.query?.contains("name=orig") == true })
        XCTAssertTrue(document.warnings.isEmpty)
        try ContentFidelityValidator.validateCanonical(document)

        for index in document.media.indices {
            document.media[index].remoteURL = URL(string: "https://images.example.test/\(document.media[index].id).jpg")
        }
        let markdown = try MarkdownRenderer.render(document: document)
        XCTAssertTrue(markdown.contains("**第一段**"))
        XCTAssertTrue(markdown.contains("3. 第三项"))
        XCTAssertTrue(markdown.contains("| 阶段 | 形态 |\n| --- | --- |\n| 验证 | **OPC** |"))
        XCTAssertTrue(markdown.contains("```python\nprint(1)\n```"))
        let tableRange = try XCTUnwrap(markdown.range(of: "| 阶段 | 形态 |"))
        let codeRange = try XCTUnwrap(markdown.range(of: "print(1)"))
        let imageRange = try XCTUnwrap(markdown.range(of: "body.jpg"))
        XCTAssertTrue(tableRange.lowerBound < codeRange.lowerBound)
        XCTAssertTrue(codeRange.lowerBound < imageRange.lowerBound)
        try MarkdownRenderer.validateRenderedText(document: document, markdown: markdown)
    }

    func testRejectsWrongPostUnknownBlockAndChangedSourceText() {
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        let body = [BrowserCapturedBlock(kind: .paragraph, text: "正文")]
        let context = BrowserArticleCaptureContext(link: link, creator: creator, expectedPlainText: "正文")

        XCTAssertThrowsError(try BrowserArticleCaptureDecoder.decode(
            BrowserArticleCapturePayload(
                postID: "999", title: "标题", pageURL: "https://x.com/writer/status/999", blocks: body
            ),
            context: context
        ))
        XCTAssertThrowsError(try BrowserArticleCaptureDecoder.decode(
            BrowserArticleCapturePayload(
                postID: link.postID, title: "标题", pageURL: link.originalURL.absoluteString,
                blocks: body, unsupportedBlockCount: 1
            ),
            context: context
        ))
        XCTAssertThrowsError(try BrowserArticleCaptureDecoder.decode(
            BrowserArticleCapturePayload(
                postID: link.postID, title: "标题", pageURL: link.originalURL.absoluteString,
                blocks: [BrowserCapturedBlock(kind: .paragraph, text: "被篡改")]
            ),
            context: context
        ))
    }

    func testQuotedArticleCardKeepsOnlyCanonicalArticleLinkAtItsOriginalPosition() throws {
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        let quotedURL = "https://x.com/quoted_writer/status/2095455845823971411"
        let payload = BrowserArticleCapturePayload(
            postID: link.postID,
            title: "含引用卡片的文章",
            publishedAt: "2026-09-02T03:04:00.000Z",
            pageURL: link.originalURL.absoluteString,
            blocks: [
                BrowserCapturedBlock(kind: .paragraph, text: "引用前的正文"),
                BrowserCapturedBlock(
                    kind: .embeddedPost,
                    text: "作者\n@quoted_writer\nArticle\n被引用文章摘要\n13\n39\n135",
                    links: [
                        BrowserCapturedLink(offset: 0, length: 2, url: "https://x.com/quoted_writer"),
                        BrowserCapturedLink(offset: 0, length: 2, url: quotedURL)
                    ]
                ),
                BrowserCapturedBlock(kind: .paragraph, text: "引用后的正文")
            ]
        )
        let context = BrowserArticleCaptureContext(
            link: link,
            creator: creator,
            expectedPlainText: "引用前的正文\n引用后的正文"
        )

        let document = try BrowserArticleCaptureDecoder.decode(payload, context: context)
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph, .embeddedPost, .paragraph])
        XCTAssertEqual(document.blocks.count, 3)
        let quotedBlock = document.blocks[1]
        XCTAssertEqual(quotedBlock.text, quotedURL)
        XCTAssertEqual(quotedBlock.links.map { $0.url.absoluteString }, [quotedURL])
        XCTAssertEqual(quotedBlock.sourceEntityType, "browser-rendered-article-link")

        let markdown = try MarkdownRenderer.render(document: document)
        XCTAssertTrue(markdown.contains("引用前的正文\n\n引用文章：<\(quotedURL)>\n\n引用后的正文"))
        XCTAssertFalse(markdown.contains("被引用文章摘要"))
        XCTAssertFalse(markdown.contains("https://x.com/quoted_writer)"))
        try MarkdownRenderer.validateRenderedText(document: document, markdown: markdown)
    }

    func testQuotedArticleURLNormalizationRejectsProfilesAndMediaLinks() throws {
        XCTAssertEqual(
            BrowserArticleCaptureDecoder.normalizedEmbeddedArticleURL(
                from: "https://twitter.com/quoted_writer/status/2095455845823971411"
            )?.absoluteString,
            "https://x.com/quoted_writer/status/2095455845823971411"
        )
        XCTAssertEqual(
            BrowserArticleCaptureDecoder.normalizedEmbeddedArticleURL(
                from: "https://x.com/i/article/2095455845823971411"
            )?.absoluteString,
            "https://x.com/i/article/2095455845823971411"
        )
        XCTAssertNil(BrowserArticleCaptureDecoder.normalizedEmbeddedArticleURL(
            from: "https://x.com/quoted_writer"
        ))
        XCTAssertNil(BrowserArticleCaptureDecoder.normalizedEmbeddedArticleURL(
            from: "https://x.com/quoted_writer/article/2095455845823971411/media/123"
        ))
    }

    func testEmbeddedVideoSelectsHighestProgressiveMP4AndRendersPlayableHTML() throws {
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        let payload = BrowserArticleCapturePayload(
            postID: link.postID,
            title: "含视频的文章",
            publishedAt: "2026-09-02T03:04:00.000Z",
            pageURL: link.originalURL.absoluteString,
            blocks: [
                BrowserCapturedBlock(kind: .paragraph, text: "视频前的正文"),
                BrowserCapturedBlock(
                    kind: .embeddedMedia,
                    text: "0:25",
                    embeddedMediaType: "video",
                    embeddedMediaID: "2095075428293840896",
                    embeddedMediaURLs: [
                        "https://video.twimg.com/amplify_video/2095075428293840896/vid/avc1/538x270/low.mp4?tag=29",
                        "https://video.twimg.com/amplify_video/2095075428293840896/vid/avc1/0/0/1438x720/init.mp4",
                        "https://video.twimg.com/amplify_video/2095075428293840896/pl/master.m3u8?tag=29",
                        "https://video.twimg.com/amplify_video/2095075428293840896/vid/avc1/1438x720/high.mp4?tag=29"
                    ],
                    posterURL: "https://pbs.twimg.com/amplify_video_thumb/2095075428293840896/img/poster.jpg",
                    durationSeconds: 25.4
                ),
                BrowserCapturedBlock(kind: .paragraph, text: "视频后的正文")
            ]
        )
        let context = BrowserArticleCaptureContext(
            link: link,
            creator: creator,
            expectedPlainText: "视频前的正文\n视频后的正文"
        )

        var document = try BrowserArticleCaptureDecoder.decode(payload, context: context)
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph, .video, .paragraph])
        XCTAssertEqual(document.blocks[1].sourceEntityType, "browser-rendered-video")
        XCTAssertEqual(document.blocks[1].mediaID, "2095075428293840896")
        let video = try XCTUnwrap(document.videos?.first)
        XCTAssertEqual(video.sourceURL.absoluteString, "https://video.twimg.com/amplify_video/2095075428293840896/vid/avc1/1438x720/high.mp4?tag=29")
        XCTAssertEqual(video.posterURL?.absoluteString, "https://pbs.twimg.com/amplify_video_thumb/2095075428293840896/img/poster.jpg")
        XCTAssertEqual(video.durationSeconds, 25.4)
        XCTAssertTrue(document.warnings.isEmpty)

        document.videos?[0].remoteURL = URL(string: "https://media.example.test/archive/video.mp4")
        let markdown = try MarkdownRenderer.render(document: document)
        XCTAssertTrue(markdown.contains("videos_count: 1"))
        XCTAssertTrue(markdown.contains("<video controls preload=\"metadata\" src=\"https://media.example.test/archive/video.mp4\"></video>"))
        XCTAssertTrue(markdown.contains("[打开或下载视频](https://media.example.test/archive/video.mp4)"))
        try MarkdownRenderer.validateRenderedText(document: document, markdown: markdown)

        let videoOnlyPayload = BrowserArticleCapturePayload(
            postID: link.postID,
            title: "只有视频的文章",
            publishedAt: "2026-09-02T03:04:00.000Z",
            pageURL: link.originalURL.absoluteString,
            blocks: [payload.blocks[1]]
        )
        let videoOnlyDocument = try BrowserArticleCaptureDecoder.decode(
            videoOnlyPayload,
            context: BrowserArticleCaptureContext(link: link, creator: creator)
        )
        XCTAssertEqual(videoOnlyDocument.blocks.map(\.kind), [.video])
        XCTAssertEqual(videoOnlyDocument.videos?.count, 1)
    }

    func testAcceptsOnlyRealArticleMediaAndRejectsAvatarOrEmojiImages() throws {
        let article = try XCTUnwrap(BrowserArticleCaptureDecoder.originalImageURL(
            from: "https://pbs.twimg.com/media/real-image?format=jpg&name=small"
        ))
        XCTAssertEqual(article.host, "pbs.twimg.com")
        XCTAssertTrue(article.path.hasPrefix("/media/"))
        XCTAssertTrue(article.query?.contains("name=orig") == true)
        XCTAssertNil(BrowserArticleCaptureDecoder.originalImageURL(
            from: "https://pbs.twimg.com/profile_images/123/avatar.jpg"
        ))
        XCTAssertNil(BrowserArticleCaptureDecoder.originalImageURL(
            from: "https://abs-0.twimg.com/emoji/v2/svg/1f680.svg"
        ))
    }
}

final class UPicOutputParserTests: XCTestCase {
    func testParsesOnlyURLsAfterOutputMarker() throws {
        let output = """
        Total paths count: 2
        Uploading 1/2
        Uploading 2/2
        Output URL:
        https://img.example.test/a.png
        https://img.example.test/b.png
        """
        XCTAssertEqual(try UPicOutputParser.parse(output).map(\.absoluteString), [
            "https://img.example.test/a.png",
            "https://img.example.test/b.png"
        ])
    }

    func testRejectsInsecureAndEmptyOutput() {
        XCTAssertThrowsError(try UPicOutputParser.parse("Output URL:\nfile:///tmp/a.png\n"))
    }
}

final class S3ImageHostAdapterTests: XCTestCase {
    func testBuildsDeterministicR2SigV4RequestWithoutExposingSecret() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "x-s3-sign-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "image.png")
        try Data("test-image".utf8).write(to: file)
        let configuration = S3ImageHostConfiguration(
            endpoint: URL(string: "https://account.r2.cloudflarestorage.com")!,
            bucket: "images",
            publicBaseURL: URL(string: "https://img.example.test")!,
            region: "auto",
            keyPrefix: "x-archive/test"
        )
        let adapter = S3ImageHostAdapter(configuration: configuration, accessKey: "ACCESS123", secretKey: "SECRET456")
        let request = try adapter.signedRequestForTesting(fileURL: file, date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertTrue(request.url!.absoluteString.contains("/images/x-archive/test/"))
        XCTAssertTrue(request.url!.absoluteString.hasSuffix(".png"))
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.contains("Credential=ACCESS123/19700101/auto/s3/aws4_request"))
        XCTAssertFalse(authorization.contains("SECRET456"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "19700101T000000Z")
    }

    func testSignsMP4UploadsWithVideoContentTypeAndExtension() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "x-s3-video-sign-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "video.mp4")
        try Data("synthetic-mp4".utf8).write(to: file)
        let configuration = S3ImageHostConfiguration(
            endpoint: URL(string: "https://account.r2.cloudflarestorage.com")!,
            bucket: "media",
            publicBaseURL: URL(string: "https://media.example.test")!,
            region: "auto",
            keyPrefix: "x-archive/video"
        )
        let adapter = S3ImageHostAdapter(configuration: configuration, accessKey: "ACCESS123", secretKey: "SECRET456")

        let request = try adapter.signedRequestForTesting(fileURL: file, date: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertTrue(request.url?.absoluteString.hasSuffix(".mp4") == true)
        XCTAssertTrue(request.url?.path.contains("/media/x-archive/video/") == true)
    }
}

final class VideoDownloaderTests: XCTestCase {
    func testDownloadsRealXProgressiveMP4WhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_X_VIDEO_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_X_VIDEO_INTEGRATION=1 to download and validate one public X progressive MP4")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "x-video-download-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = VideoAsset(
            id: "2095075428293840896",
            sourceURL: URL(string: "https://video.twimg.com/amplify_video/2095075428293840896/vid/avc1/1438x720/Tm4o1AUqnBJp5VqV.mp4?tag=29")!,
            posterURL: URL(string: "https://pbs.twimg.com/amplify_video_thumb/2095075428293840896/img/vYpK9Ho6KdDCJgBp.jpg")!,
            position: 0,
            durationSeconds: 26
        )

        let cached = try await VideoDownloader().cache(video, in: root)

        let path = try XCTUnwrap(cached.localCachePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.int64Value ?? 0, 1_000_000)
        XCTAssertTrue(path.hasSuffix(".mp4"))
        XCTAssertEqual(cached.sha256?.count, 64)
        let prefix = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(12)
        XCTAssertEqual(String(data: Data(prefix.dropFirst(4).prefix(4)), encoding: .ascii), "ftyp")
    }
}

final class UPicConfigurationReaderTests: XCTestCase {
    func testReadsSandboxPreferenceAndNormalizesR2Profile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "x-upic-config-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = root.appending(path: "com.svend.uPic.macos.plist")
        let inner: [String: Any] = [
            "endpoint": "https://account.r2.cloudflarestorage.com/archive-images",
            "domain": "https://img.example.test",
            "bucket": "archive-images",
            "accessKey": "ACCESS",
            "secretKey": "SECRET",
            "saveKeyPath": "uPic/{filename}{.suffix}"
        ]
        let innerData = try JSONSerialization.data(withJSONObject: inner)
        let outer: [String: Any] = [
            "id": "host-1",
            "name": "我的 R2",
            "type": "s3",
            "data": String(decoding: innerData, as: UTF8.self)
        ]
        let outerData = try JSONSerialization.data(withJSONObject: outer)
        let plist: [String: Any] = [
            "uPic_DefaultHostId": "host-1",
            "uPic_hostItems": [String(decoding: outerData, as: UTF8.self)]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try plistData.write(to: preferences)

        let profile = try UPicConfigurationReader.readDefaultS3(preferencesURL: preferences)
        XCTAssertEqual(profile.name, "我的 R2")
        XCTAssertEqual(profile.configuration.endpoint.absoluteString, "https://account.r2.cloudflarestorage.com/archive-images")
        XCTAssertEqual(profile.configuration.bucket, "")
        XCTAssertEqual(profile.configuration.publicBaseURL.absoluteString, "https://img.example.test")
        XCTAssertEqual(profile.configuration.region, "auto")
        XCTAssertEqual(profile.configuration.keyPrefix, "uPic")
        XCTAssertEqual(profile.accessKey, "ACCESS")
        XCTAssertEqual(profile.secretKey, "SECRET")
    }

    func testRejectsUnsupportedDefaultHost() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "x-upic-config-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = root.appending(path: "preferences.plist")
        let outerData = try JSONSerialization.data(withJSONObject: ["id": "smms-1", "name": "SM.MS", "type": "smms", "data": "{}"])
        let plist: [String: Any] = [
            "uPic_DefaultHostId": "smms-1",
            "uPic_hostItems": [String(decoding: outerData, as: UTF8.self)]
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: preferences)
        XCTAssertThrowsError(try UPicConfigurationReader.readDefaultS3(preferencesURL: preferences))
    }
}

final class XAPIClientDownloadLimitTests: XCTestCase {
    func testLeanDiscoveryRequestsNoMediaOrAuthorExpansions() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LeanArticleDiscoveryURLProtocol.self]
        let client = XAPIClient(
            bearerToken: "TEST",
            baseURL: URL(string: "https://api.example.test")!,
            session: URLSession(configuration: configuration)
        )
        let creator = Creator(xUserID: "user-1", username: "writer", displayName: "作者")

        let result = try await client.discoverRecentArticles(
            for: creator,
            maximumArticles: 10,
            maximumScannedPosts: 300
        )

        XCTAssertEqual(result.articles.map(\.postID), ["101"])
        XCTAssertEqual(result.articles.first?.title, "低成本发现文章")
        XCTAssertEqual(result.articles.first?.expectedPlainText, "第一段\n\n第二段")
        XCTAssertEqual(result.scannedPosts, 2)
    }

    func testCountsOnlyOfficialArticlesAndIgnoresRecentPosts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecentPostsURLProtocol.self]
        let client = XAPIClient(
            bearerToken: "TEST",
            baseURL: URL(string: "https://api.example.test")!,
            session: URLSession(configuration: configuration)
        )
        let creator = Creator(xUserID: "user-1", username: "writer", displayName: "作者")
        let result = try await client.fetchRecentLongform(for: creator, maximumArticles: 10)
        XCTAssertEqual(result.documents.count, 10)
        XCTAssertTrue(result.documents.allSatisfy { $0.contentType == .xArticle })
        XCTAssertEqual(result.documents.first?.sourcePostID, "10")
        XCTAssertEqual(result.documents.last?.sourcePostID, "1")
        XCTAssertEqual(result.completeness, .partial)
        XCTAssertEqual(result.scannedPosts, 12)
    }

    func testUsesSmallFirstPageForTenArticleRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EconomicalRecentPostsURLProtocol.self]
        let client = XAPIClient(
            bearerToken: "TEST",
            baseURL: URL(string: "https://api.example.test")!,
            session: URLSession(configuration: configuration)
        )
        let creator = Creator(xUserID: "user-1", username: "writer", displayName: "作者")
        let result = try await client.fetchRecentLongform(
            for: creator,
            maximumArticles: 10,
            maximumScannedPosts: 300
        )
        XCTAssertEqual(result.documents.count, 1)
        XCTAssertEqual(result.scannedPosts, 1)
    }
}

private final class LeanArticleDiscoveryURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        let tweetFields = Set((values["tweet.fields"] ?? "").split(separator: ",").map(String.init))
        let isLean = values["max_results"] == "20"
            && tweetFields == Set(["article", "article_title", "author_id", "created_at", "edit_history_tweet_ids"])
            && values["expansions"] == nil
            && values["media.fields"] == nil
            && values["user.fields"] == nil
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: isLean ? 200 : 400,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = isLean ? Self.responseData : Data("{\"detail\":\"discovery query requested unnecessary expansions\"}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let responseData = Data("""
    {
      "data": [
        {"id":"102","created_at":"2026-09-04T09:00:00Z","article":null},
        {"id":"101","author_id":"user-1","created_at":"2026-09-04T08:00:00Z","article":{"id":"a101","title":"低成本发现文章","plain_text":"第一段\\n\\n第二段"}}
      ],
      "meta":{"result_count":2,"newest_id":"102","oldest_id":"101"}
    }
    """.utf8)
}

final class XAPIClientDirectArticleTests: XCTestCase {
    func testBatchLookupPreservesInputOrderAndClassifiesNonArticlesAndMissingPosts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectArticlesURLProtocol.self]
        let client = XAPIClient(
            bearerToken: "TEST",
            baseURL: URL(string: "https://api.example.test")!,
            session: URLSession(configuration: configuration)
        )
        let links = XArticleURLParser.parse("""
        https://x.com/first/status/101
        https://x.com/not_article/status/303
        https://x.com/missing/status/404
        https://twitter.com/second/status/202
        """)

        let result = try await client.fetchArticles(links: links)

        XCTAssertEqual(result.items.map { $0.document.sourcePostID }, ["101", "202"])
        XCTAssertEqual(result.items.map { $0.creator.xUserID }, ["author-1", "author-2"])
        XCTAssertEqual(result.nonArticleLinks.map(\.postID), ["303"])
        XCTAssertEqual(result.unavailableLinks.map(\.postID), ["404"])
        XCTAssertEqual(result.fetchedPosts, 3)
        XCTAssertEqual(result.items[0].document.media.map(\.id), ["media-101"])
        XCTAssertEqual(result.items[1].document.media.map(\.id), ["media-202"])
    }

    func testLiveDirectArticleLookupWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_X_DIRECT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_X_DIRECT_INTEGRATION=1 to retrieve one known public X Article by status URL")
        }
        let token = try XCTUnwrap(ProcessInfo.processInfo.environment["X_API_BEARER_TOKEN"])
        let links = XArticleURLParser.parse("https://x.com/wangdefou/status/2091770029713084630")
        let result = try await XAPIClient(bearerToken: token).fetchArticles(links: links)
        let document = try XCTUnwrap(result.items.first?.document)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(document.sourcePostID, "2091770029713084630")
        XCTAssertGreaterThan(document.sourcePlainText?.count ?? 0, 500)
        XCTAssertGreaterThan(document.media.count, 0)
        XCTAssertEqual(document.sourceMediaIDs, document.media.map(\.id))
        try ContentFidelityValidator.validateCanonical(document)
    }
}

private final class RecentPostsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let responseData: Data = {
        let articles: [[String: Any]] = (1...10).map { number in
            [
                "id": String(number),
                "created_at": String(format: "2026-08-%02dT08:00:00Z", number),
                "article": [
                    "id": "article-\(number)",
                    "title": "长文 \(number)",
                    "content_state": [
                        "blocks": [["type": "unstyled", "text": "正文 \(number)", "depth": 0, "inlineStyleRanges": [], "entityRanges": []]],
                        "entityMap": [:]
                    ]
                ]
            ]
        }
        let nonArticles: [[String: Any]] = [
            ["id": "12", "created_at": "2026-08-12T08:00:00Z", "note_tweet": ["text": "这是 Note Post，不是 X Article"]],
            ["id": "11", "created_at": "2026-08-11T08:00:00Z", "text": "这是最近的普通帖子"]
        ]
        let root: [String: Any] = [
            "data": nonArticles + articles,
            "meta": ["result_count": 12, "newest_id": "12", "oldest_id": "1", "next_token": "next-page"]
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }()
}

private final class EconomicalRecentPostsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let pageSize = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "max_results" })?.value
        let statusCode = pageSize == "20" ? 200 : 400
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let data: Data
        if statusCode == 200 {
            data = Data("""
            {"data":[{"id":"1","author_id":"user-1","created_at":"2026-09-04T08:00:00Z","article":{"id":"a1","title":"文章","content_state":{"blocks":[{"type":"unstyled","text":"正文","depth":0,"inlineStyleRanges":[],"entityRanges":[]}],"entityMap":{}}}}],"meta":{"result_count":1}}
            """.utf8)
        } else {
            data = Data("{\"detail\":\"expected economical max_results=20\"}".utf8)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class DirectArticlesURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let ids = query.first(where: { $0.name == "ids" })?.value
        let expansions = query.first(where: { $0.name == "expansions" })?.value ?? ""
        let isEconomical = ids == "101,303,404,202"
            && !expansions.split(separator: ",").contains("author_id")
        let statusCode = isEconomical ? 200 : 400
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = statusCode == 200 ? Self.responseData : Data("{\"detail\":\"unexpected direct lookup query\"}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let responseData = Data("""
    {
      "data": [
        {"id":"202","author_id":"author-2","created_at":"2026-09-03T08:00:00Z","article":{"id":"a202","title":"第二篇","plain_text":"第二篇第一段\\n\\n第二篇第二段","media_entities":["media-202"]}},
        {"id":"303","author_id":"author-3","created_at":"2026-09-02T08:00:00Z","text":"普通帖子"},
        {"id":"101","author_id":"author-1","created_at":"2026-09-04T08:00:00Z","article":{"id":"a101","title":"第一篇","plain_text":"第一篇正文","media_entities":["media-101"]}}
      ],
      "includes": {"media": [
        {"type":"photo","media_key":"media-202","url":"https://pbs.twimg.com/media/202.jpg"},
        {"type":"photo","media_key":"media-101","url":"https://pbs.twimg.com/media/101.jpg"}
      ]}
    }
    """.utf8)
}

final class ArchiveDatabaseTests: XCTestCase {
    func testRoundTripsCreatorAndArticle() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "x-archive-db-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ArchiveDatabase(url: root.appending(path: "archive.sqlite"))
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        try await database.upsertCreator(creator)
        let article = ArchivedArticle(
            stableSourceKey: "a1",
            creatorID: creator.id,
            title: "文章",
            authorHandle: creator.username,
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/1")!,
            sourcePostID: "1",
            publishedAt: Date(timeIntervalSince1970: 0),
            sourceChecksum: "abc",
            videoCount: 2,
            pipelineState: .committed
        )
        try await database.upsertArticle(article)
        let loadedCreators = try await database.loadCreators()
        XCTAssertEqual(loadedCreators.count, 1)
        let loaded = try await database.loadArticles()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.stableSourceKey, "a1")
        XCTAssertEqual(loaded.first?.videoCount, 2)
    }

    func testDeletesOnlyTheRequestedArticle() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "x-archive-delete-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ArchiveDatabase(url: root.appending(path: "archive.sqlite"))
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        try await database.upsertCreator(creator)
        let first = ArchivedArticle(
            stableSourceKey: "article-delete",
            creatorID: creator.id,
            title: "要删除",
            authorHandle: creator.username,
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/1")!,
            sourcePostID: "1",
            publishedAt: Date(timeIntervalSince1970: 1),
            sourceChecksum: "one"
        )
        let second = ArchivedArticle(
            stableSourceKey: "article-keep",
            creatorID: creator.id,
            title: "要保留",
            authorHandle: creator.username,
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/2")!,
            sourcePostID: "2",
            publishedAt: Date(timeIntervalSince1970: 2),
            sourceChecksum: "two"
        )
        try await database.upsertArticle(first)
        try await database.upsertArticle(second)

        try await database.deleteArticle(id: first.id)

        let remaining = try await database.loadArticles()
        XCTAssertEqual(remaining.map(\.id), [second.id])
    }

    func testSoftDeletingCreatorKeepsArticlesAndAllowsReenableWithSameIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "x-archive-creator-delete-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ArchiveDatabase(url: root.appending(path: "archive.sqlite"))
        var creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        try await database.upsertCreator(creator)
        let article = ArchivedArticle(
            stableSourceKey: "article-keep",
            creatorID: creator.id,
            title: "保留文章",
            authorHandle: creator.username,
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/2")!,
            sourcePostID: "2",
            publishedAt: Date(timeIntervalSince1970: 2),
            sourceChecksum: "two"
        )
        try await database.upsertArticle(article)

        try await database.setCreatorEnabled(id: creator.id, isEnabled: false)
        let disabled = try await database.creator(xUserID: "u1")
        XCTAssertEqual(disabled?.id, creator.id)
        XCTAssertEqual(disabled?.isEnabled, false)
        let articlesAfterRemoval = try await database.loadArticles()
        XCTAssertEqual(articlesAfterRemoval.map(\.id), [article.id])

        creator.isEnabled = true
        try await database.upsertCreator(creator)
        let enabled = try await database.creator(xUserID: "u1")
        XCTAssertEqual(enabled?.id, creator.id)
        XCTAssertEqual(enabled?.isEnabled, true)
        let cachedByHandle = try await database.creator(username: "WRITER")
        XCTAssertEqual(cachedByHandle?.xUserID, "u1")
    }
}

final class ExactCaptureQueuePolicyTests: XCTestCase {
    private let creatorID = UUID()

    func testUnfinishedPlaceholderIsQueuedAndRemovedWhenTaskIsDismissed() {
        let article = makeArticle(
            pipelineState: .discovered,
            warnings: ["等待在应用内打开 X Article 并保存精确排版"]
        )

        XCTAssertTrue(ExactCaptureQueuePolicy.needsCapture(article))
        XCTAssertNil(ExactCaptureQueuePolicy.articleAfterDismissingTask(article))
    }

    func testDeletingTaskPreservesExistingArchiveAndPermanentlyDismissesRetry() {
        let article = makeArticle(
            markdownPath: "/tmp/article.md",
            pipelineState: .committed,
            warnings: ["X API 未提供段落级富文本块"]
        )

        let preserved = ExactCaptureQueuePolicy.articleAfterDismissingTask(article)

        XCTAssertNotNil(preserved)
        XCTAssertEqual(preserved?.markdownPath, "/tmp/article.md")
        XCTAssertEqual(preserved?.pipelineState, .committed)
        XCTAssertTrue(preserved?.warnings.contains(ExactCaptureQueuePolicy.dismissedWarning) == true)
        XCTAssertFalse(ExactCaptureQueuePolicy.needsCapture(preserved!))
    }

    func testDeletingFailedRetryKeepsPreviouslyWrittenMarkdown() {
        let article = makeArticle(
            markdownPath: "/tmp/existing.md",
            pipelineState: .failed,
            warnings: ["富文本样式可能不完整"],
            lastError: "capture failed"
        )

        let preserved = ExactCaptureQueuePolicy.articleAfterDismissingTask(article)

        XCTAssertEqual(preserved?.pipelineState, .committed)
        XCTAssertNil(preserved?.lastError)
        XCTAssertEqual(preserved?.markdownPath, "/tmp/existing.md")
        XCTAssertFalse(ExactCaptureQueuePolicy.needsCapture(preserved!))
    }

    func testValidatedCommittedArticleNeverEntersQueue() {
        let article = makeArticle(markdownPath: "/tmp/complete.md", pipelineState: .committed)
        XCTAssertFalse(ExactCaptureQueuePolicy.needsCapture(article))
    }

    func testDismissalSurvivesDatabaseReload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "x-exact-capture-dismiss-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ArchiveDatabase(url: root.appending(path: "archive.sqlite"))
        let creator = Creator(id: creatorID, xUserID: "u1", username: "writer", displayName: "作者")
        try await database.upsertCreator(creator)
        let article = makeArticle(
            markdownPath: "/tmp/preserved.md",
            pipelineState: .committed,
            warnings: ["精确插入位置无法还原"]
        )
        try await database.upsertArticle(article)

        let dismissed = try XCTUnwrap(ExactCaptureQueuePolicy.articleAfterDismissingTask(article))
        try await database.upsertArticle(dismissed)
        let stored = try await database.article(sourcePostID: article.sourcePostID)
        let reloaded = try XCTUnwrap(stored)

        XCTAssertFalse(ExactCaptureQueuePolicy.needsCapture(reloaded))
        XCTAssertEqual(reloaded.markdownPath, article.markdownPath)
    }

    private func makeArticle(
        markdownPath: String? = nil,
        pipelineState: PipelineState,
        warnings: [String] = [],
        lastError: String? = nil
    ) -> ArchivedArticle {
        ArchivedArticle(
            stableSourceKey: UUID().uuidString,
            creatorID: creatorID,
            title: "测试文章",
            authorHandle: "writer",
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/1")!,
            sourcePostID: "1",
            publishedAt: .distantPast,
            sourceChecksum: "checksum",
            markdownPath: markdownPath,
            pipelineState: pipelineState,
            warnings: warnings,
            lastError: lastError
        )
    }
}

private struct NoopImageHost: ImageHostAdapter {
    var displayName: String { "Noop" }
    func probe() async -> ImageHostCapability {
        ImageHostCapability(name: displayName, version: "1", isAvailable: true, detail: "ready")
    }
    func upload(fileURLs: [URL]) async throws -> [UploadResult] { [] }
    func verify(remoteURL: URL) async throws {}
}

final class SyncProgressTests: XCTestCase {
    func testSyncAllCreatorPolicyKeepsMoreThanOneHundredEnabledCreatorsWithoutTruncation() {
        var creators = (1...137).map { index in
            Creator(
                xUserID: "user-\(index)",
                username: "creator_\(index)",
                displayName: "Creator \(index)"
            )
        }
        creators.append(Creator(
            xUserID: "disabled",
            username: "disabled_creator",
            displayName: "Disabled",
            isEnabled: false
        ))
        creators.append(Creator(
            xUserID: "duplicate",
            username: "CREATOR_1",
            displayName: "Duplicate"
        ))

        let usernames = SyncAllCreatorPolicy.enabledUsernames(from: creators)

        XCTAssertEqual(usernames.count, 137)
        XCTAssertEqual(usernames.first, "creator_1")
        XCTAssertEqual(usernames.last, "creator_137")
        XCTAssertFalse(usernames.contains("disabled_creator"))
    }

    func testTracksSkippedArticlesIndependentlyFromSavedAndFailedCounts() {
        let progress = SyncProgress(
            stage: "同步中",
            discoveredArticles: 10,
            completedArticles: 2,
            skippedArticles: 7,
            uploadedImages: 4,
            failedArticles: 1
        )

        XCTAssertEqual(progress.discoveredArticles, 10)
        XCTAssertEqual(progress.completedArticles, 2)
        XCTAssertEqual(progress.skippedArticles, 7)
        XCTAssertEqual(progress.failedArticles, 1)
    }
}

final class ScheduledSyncTests: XCTestCase {
    func testLaunchAgentRunsDailyThroughTheHiddenApplicationCallback() throws {
        let configuration = ScheduledSyncConfiguration(
            isEnabled: true,
            hour: 2,
            minute: 35,
            articleLimit: 20
        )

        let data = try ScheduledSyncLaunchAgentDescriptor.propertyListData(for: configuration)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let calendar = try XCTUnwrap(plist["StartCalendarInterval"] as? [String: Int])
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])

        XCTAssertEqual(calendar["Hour"], 2)
        XCTAssertEqual(calendar["Minute"], 35)
        XCTAssertEqual(arguments, [
            "/usr/bin/open",
            "-gj",
            "-b",
            ScheduledSyncLaunchAgentDescriptor.appBundleIdentifier,
            ScheduledSyncLaunchAgentDescriptor.callbackURL
        ])
        XCTAssertEqual(plist["ProcessType"] as? String, "Background")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, false)
    }

    func testScheduledSyncConfigurationRejectsInvalidTimeAndArticleLimit() {
        XCTAssertTrue(ScheduledSyncConfiguration(
            isEnabled: true,
            hour: 23,
            minute: 59,
            articleLimit: 100
        ).isValid)
        XCTAssertFalse(ScheduledSyncConfiguration(
            isEnabled: true,
            hour: 24,
            minute: 0,
            articleLimit: 10
        ).isValid)
        XCTAssertFalse(ScheduledSyncConfiguration(
            isEnabled: true,
            hour: 2,
            minute: 0,
            articleLimit: 101
        ).isValid)
    }
}

final class ArchiveIndexWriterTests: XCTestCase {
    func testRebuildCreatesAnEmptyCreatorDirectoryForDeletedPendingArticle() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "x-archive-empty-index-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let creator = Creator(xUserID: "u1", username: "new_writer", displayName: "新博主")

        try ArchiveIndexWriter.rebuild(root: root, creator: creator)

        let directory = root.appending(path: SafeFileName.creatorDirectory(
            handle: creator.username,
            displayName: creator.displayName
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "articles").path))
        let index = try String(contentsOf: directory.appending(path: "index.md"), encoding: .utf8)
        XCTAssertTrue(index.contains("共 0 篇本地长文"))
    }
}

final class ArchivePipelineTests: XCTestCase {
    func testLocalMediaStorageCopiesImageAndVideoAndWritesPortableMarkdownPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "x-archive-local-media-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let staging = root.appending(path: "capture-cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let imageCache = staging.appending(path: "source.png")
        try png.write(to: imageCache)
        let mp4 = Data([
            0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
            0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x02, 0x00,
            0x69, 0x73, 0x6F, 0x6D, 0x69, 0x73, 0x6F, 0x32
        ])
        let videoCache = staging.appending(path: "source.mp4")
        try mp4.write(to: videoCache)

        let database = try ArchiveDatabase(
            url: root.appending(path: ".x-article-archiver/archive.sqlite")
        )
        let creator = Creator(xUserID: "local-media-user", username: "writer", displayName: "作者")
        try await database.upsertCreator(creator)
        let document = CanonicalDocument(
            title: "本地媒体归档",
            authorName: creator.displayName,
            authorHandle: creator.username,
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/199")!,
            sourcePostID: "199",
            sourceArticleID: "article-local-media-199",
            publishedAt: Date(timeIntervalSince1970: 0),
            blocks: [
                CanonicalBlock(kind: .paragraph, text: "正文保持原样。"),
                CanonicalBlock(kind: .image, mediaID: "image-1"),
                CanonicalBlock(kind: .video, mediaID: "video-1")
            ],
            media: [MediaAsset(
                id: "image-1",
                sourceURL: URL(string: "https://pbs.twimg.com/media/source.png")!,
                altText: "本地图片",
                position: 0,
                localCachePath: imageCache.path
            )],
            videos: [VideoAsset(
                id: "video-1",
                sourceURL: URL(string: "https://video.twimg.com/ext_tw_video/source.mp4")!,
                position: 0,
                localCachePath: videoCache.path
            )],
            sourceMediaIDs: ["image-1"],
            sourceVideoIDs: ["video-1"],
            layoutFidelity: .renderedPageVerified
        )

        let adapter = LocalMediaHostAdapter(archiveRoot: root)
        let pipeline = ArchivePipeline(database: database, imageHost: adapter)
        let archived = try await pipeline.archive(document: document, creator: creator, root: root)
        let markdownPath = try XCTUnwrap(archived.markdownPath)
        let markdown = try String(contentsOfFile: markdownPath, encoding: .utf8)

        XCTAssertTrue(markdown.contains("![本地图片](../../media/images/"))
        XCTAssertTrue(markdown.contains("<video controls preload=\"metadata\" src=\"../../media/videos/"))
        XCTAssertTrue(markdown.contains("[打开或下载视频](../../media/videos/"))
        XCTAssertFalse(markdown.contains(imageCache.path))
        XCTAssertFalse(markdown.contains(videoCache.path))

        let localImages = try FileManager.default.contentsOfDirectory(
            at: root.appending(path: "media/images"),
            includingPropertiesForKeys: nil
        )
        let localVideos = try FileManager.default.contentsOfDirectory(
            at: root.appending(path: "media/videos"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(localImages.count, 1)
        XCTAssertEqual(localVideos.count, 1)
        try await adapter.verify(remoteURL: URL(string: "media/images/\(localImages[0].lastPathComponent)")!)
        try await adapter.verifyVideo(remoteURL: URL(string: "media/videos/\(localVideos[0].lastPathComponent)")!)

        let snapshotURL = root
            .appending(path: ".x-article-archiver/source-snapshots")
            .appending(path: "article-local-media-199.json")
        let snapshotData = try Data(contentsOf: snapshotURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CanonicalDocument.self, from: snapshotData)
        XCTAssertTrue(snapshot.media[0].remoteURL?.relativeString.hasPrefix("media/images/") == true)
        XCTAssertTrue(snapshot.videos?[0].remoteURL?.relativeString.hasPrefix("media/videos/") == true)
    }

    func testPipelineIsIdempotentAndDoesNotMistakeOwnChecksumForLocalEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "x-archive-pipeline-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ArchiveDatabase(url: root.appending(path: ".x-article-archiver/archive.sqlite"))
        let creator = Creator(xUserID: "u1", username: "writer", displayName: "作者")
        try await database.upsertCreator(creator)
        let document = CanonicalDocument(
            title: "可以重复执行",
            authorName: creator.displayName,
            authorHandle: creator.username,
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/writer/status/99")!,
            sourcePostID: "99",
            sourceArticleID: "article-99",
            publishedAt: Date(timeIntervalSince1970: 0),
            blocks: [CanonicalBlock(kind: .paragraph, text: "正文保持不变。")]
        )
        let pipeline = ArchivePipeline(database: database, imageHost: NoopImageHost())
        let first = try await pipeline.archive(document: document, creator: creator, root: root)
        let second = try await pipeline.archive(document: document, creator: creator, root: root)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.markdownPath, second.markdownPath)
        let files = try FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: first.markdownPath!).deletingLastPathComponent().path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".md") }.count, 1)
    }

    func testUPicLiveIntegrationWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_UPIC_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RUN_UPIC_INTEGRATION=1 to upload one synthetic 1x1 PNG through uPic's current default host")
        }
        // uPic's App Store build cannot read another app's private temporary
        // directory. The product likewise stages media below the user-selected
        // archive root, so this guarded integration test uses the checked-out
        // repository as its explicitly accessible staging root.
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".x-upic-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let file = directory.appending(path: "X长文归档器-uPic联调.png")
        try png.write(to: file)
        let adapter = UPicAdapter()
        let capability = await adapter.probe()
        XCTAssertTrue(capability.isAvailable)
        let results = try await adapter.upload(fileURLs: [file])
        XCTAssertEqual(results.count, 1)
        try await adapter.verify(remoteURL: results[0].remoteURL)
    }
}
