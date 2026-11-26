import WebKit
import XCTest
@testable import XArticleArchiverApp
@testable import XArticleArchiverCore

/// Regressions for "没有读到正文": new X modules, videos without MP4
/// variants, lazily loaded images, and non-Article posts.
@MainActor
final class BrowserCaptureCompatibilityTests: XCTestCase {
    private let postID = "2049065078843195696"
    private let imageStubs = """
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'none'; script-src 'unsafe-inline'">
    <script>
      Object.defineProperty(HTMLImageElement.prototype, 'complete', {get: () => true});
      Object.defineProperty(HTMLImageElement.prototype, 'naturalWidth', {get: () => 1200});
    </script>
    """

    private func article(_ body: String, title: String = "兼容性测试") -> String {
        """
        <!doctype html>
        \(imageStubs)
        <article>
          <a href="/writer">测试作者</a>
          <time datetime="2026-09-02T03:04:00.000Z"></time>
          <div data-testid="twitterArticleReadView">
            <h1 data-testid="twitter-article-title">\(title)</h1>
            <div data-testid="longformRichTextComponent">\(body)</div>
          </div>
        </article>
        """
    }

    private func run(_ html: String, flags: String = "") async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_100, height: 820), configuration: configuration)
        let loader = FixtureLoader()
        webView.navigationDelegate = loader
        try await loader.load(html, in: webView, baseURL: URL(string: "https://x.com/writer/status/\(postID)")!)
        let raw = try await webView.evaluateJavaScript(flags + BrowserArticleExtractionScript.source)
        return try XCTUnwrap(raw as? String)
    }

    private func payload(_ json: String) throws -> BrowserArticleCapturePayload {
        XCTAssertFalse(json.hasPrefix("__X_CAPTURE_"), json)
        return try JSONDecoder().decode(BrowserArticleCapturePayload.self, from: Data(json.utf8))
    }

    private var context: BrowserArticleCaptureContext {
        get throws {
            let link = try XCTUnwrap(XArticleURLParser.parse("https://x.com/writer/status/\(postID)").first)
            return BrowserArticleCaptureContext(
                link: link,
                creator: Creator(xUserID: "writer-id", username: "writer", displayName: "测试作者")
            )
        }
    }

    func testUnknownModulesKeepTheirTextInsteadOfFailingTheArticle() async throws {
        let html = article("""
          <div class="longform-unstyled" data-block="true"><span data-text="true">第一段</span></div>
          <section data-block="true"><div class="callout"><strong>提示</strong><br>这是一个新的提示模块</div></section>
          <aside data-block="true"><span data-text="true">旁注模块</span></aside>
          <section data-block="true"><div class="poll">投票：A 还是 B</div></section>
          <div class="longform-unstyled" data-block="true"><span data-text="true">最后一段</span></div>
        """)
        let captured = try payload(try await run(html))
        XCTAssertEqual(captured.unsupportedBlockCount, 0)
        XCTAssertTrue(ArticleCaptureStabilityPolicy.isStructurallyComplete(captured))
        let texts = captured.blocks.map(\.text)
        XCTAssertEqual(texts.first, "第一段")
        XCTAssertEqual(texts.last, "最后一段")
        XCTAssertTrue(texts.contains("这是一个新的提示模块"), "\(texts)")
        XCTAssertTrue(texts.contains("旁注模块"), "\(texts)")
        XCTAssertTrue(texts.contains("投票：A 还是 B"), "\(texts)")
        let document = try BrowserArticleCaptureDecoder.decode(captured, context: try context)
        XCTAssertEqual(document.contentType, .xArticle)
    }

    func testVideoWithoutMP4WaitsThenBecomesASourceLinkedPlaceholder() async throws {
        let html = article("""
          <div class="longform-unstyled" data-block="true"><span data-text="true">视频前</span></div>
          <section data-block="true"><div data-testid="videoPlayer"><video src="blob:https://x.com/abc" poster="https://pbs.twimg.com/amplify_video_thumb/1234567890/img/a.jpg"></video></div></section>
          <div class="longform-unstyled" data-block="true"><span data-text="true">视频后</span></div>
        """)
        let early = try await run(html)
        XCTAssertTrue(early.contains("视频正在解析真实 MP4 地址"), early)

        let late = try payload(try await run(html, flags: "window.__markxMediaGraceExpired = true;\n"))
        XCTAssertFalse(ArticleCaptureStabilityPolicy.isStructurallyComplete(late))
        XCTAssertTrue(ArticleCaptureStabilityPolicy.isStructurallyComplete(late, allowUnresolvedVideo: true))
        XCTAssertEqual(ArticleCaptureStabilityPolicy.incompleteReason(late), "视频地址还没有解析出来")

        let document = try BrowserArticleCaptureDecoder.decode(late, context: try context)
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph, .unsupported, .paragraph])
        XCTAssertTrue(document.blocks[1].text.hasPrefix("视频未能转存"), document.blocks[1].text)
        XCTAssertTrue(document.warnings.contains { $0.contains("没有读到 MP4 地址的视频") })
    }

    func testImageOnlyArticleIsNotReportedAsEmpty() async throws {
        let html = article("""
          <section data-block="true"><a href="/writer/status/\(postID)/media/101"><div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/a?format=jpg&amp;name=medium"></div></a></section>
        """)
        let captured = try payload(try await run(html))
        XCTAssertEqual(captured.blocks.map(\.kind), [.image])
        XCTAssertTrue(ArticleCaptureStabilityPolicy.isStructurallyComplete(captured))
    }

    func testPendingLazyImagesAreForcedToLoad() async throws {
        let html = """
        <!doctype html>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'none'; script-src 'unsafe-inline'">
        <article>
          <a href="/writer">测试作者</a>
          <time datetime="2026-09-02T03:04:00.000Z"></time>
          <div data-testid="twitterArticleReadView">
            <h1 data-testid="twitter-article-title">懒加载</h1>
            <div data-testid="longformRichTextComponent">
              <div class="longform-unstyled" data-block="true"><span data-text="true">正文</span></div>
              <section data-block="true"><a href="/writer/status/\(postID)/media/101"><div data-testid="tweetPhoto"><img id="lazy" loading="lazy" src="https://pbs.twimg.com/media/a?format=jpg&amp;name=medium"></div></a></section>
            </div>
          </div>
        </article>
        """
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1_100, height: 820), configuration: configuration)
        let loader = FixtureLoader()
        webView.navigationDelegate = loader
        try await loader.load(html, in: webView, baseURL: URL(string: "https://x.com/writer/status/\(postID)")!)
        let raw = try await webView.evaluateJavaScript(BrowserArticleExtractionScript.source) as? String
        XCTAssertTrue(raw?.contains("文章原图还没有完整加载（还差 1 张）") == true, raw ?? "nil")
        let loading = try await webView.evaluateJavaScript("document.getElementById('lazy').loading") as? String
        XCTAssertEqual(loading, "eager")
    }

    private func postPage(_ tweets: String) -> String {
        """
        <!doctype html>
        \(imageStubs)
        <main>\(tweets)</main>
        """
    }

    private func tweet(id: String, handle: String = "writer", text: String, extra: String = "") -> String {
        """
        <article data-testid="tweet">
          <div data-testid="User-Name"><a href="/\(handle)"><span>测试作者</span></a><a href="/\(handle)"><span>@\(handle)</span></a></div>
          <a href="/\(handle)/status/\(id)"><time datetime="2026-09-02T03:04:00.000Z"></time></a>
          <div data-testid="tweetText">\(text)</div>
          \(extra)
        </article>
        """
    }

    func testLongPostIsArchivedOnlyAfterTheArticleGrace() async throws {
        let html = postPage(tweet(
            id: postID,
            text: "长帖标题行<br><br>第二段，带<a href=\"https://t.co/abc\">example.com/abc…</a>链接<br>第三段",
            extra: """
            <div data-testid="tweetPhoto"><img src="https://pbs.twimg.com/media/p1?format=jpg&amp;name=small" alt="配图"></div>
            <div role="link"><a href="/other/status/1999999999999999999"><time datetime="2026-01-01T00:00:00.000Z"></time></a><div data-testid="tweetText">被引用的内容</div></div>
            """
        ))
        let early = try await run(html)
        XCTAssertTrue(early.hasPrefix("__X_CAPTURE_DIAGNOSTIC__:"), early)

        let captured = try payload(try await run(html, flags: "window.__markxAllowPostFallback = true;\n"))
        XCTAssertEqual(captured.contentType, "long_post")
        XCTAssertEqual(captured.title, "长帖标题行")
        XCTAssertEqual(captured.blocks.map(\.kind), [.paragraph, .blankLine, .paragraph, .paragraph, .image, .embeddedPost])
        XCTAssertEqual(captured.blocks[2].links.first?.url, "https://t.co/abc")
        XCTAssertEqual(captured.blocks[2].links.first.map { (captured.blocks[2].text as NSString).substring(with: NSRange(location: $0.offset, length: $0.length)) }, "example.com/abc…")
        XCTAssertFalse(captured.blocks.contains { $0.text.contains("被引用的内容") })
        XCTAssertTrue(ArticleCaptureStabilityPolicy.isStructurallyComplete(captured))

        let document = try BrowserArticleCaptureDecoder.decode(captured, context: try context)
        XCTAssertEqual(document.contentType, .longPost)
        XCTAssertEqual(document.media.count, 1)
        XCTAssertEqual(document.blocks.last?.kind, .embeddedPost)
    }

    func testAuthorThreadCollectsConsecutiveSelfReplies() async throws {
        let html = postPage(
            tweet(id: postID, text: "线程第一条")
            + tweet(id: "2049065078843195697", text: "线程第二条")
            + tweet(id: "2049065078843195698", handle: "someone", text: "别人的回复")
            + tweet(id: "2049065078843195699", text: "作者后面的回复")
        )
        let captured = try payload(try await run(html, flags: "window.__markxAllowPostFallback = true;\n"))
        XCTAssertEqual(captured.contentType, "thread")
        XCTAssertEqual(captured.blocks.filter { $0.kind == .paragraph }.map(\.text), ["线程第一条", "线程第二条"])
        let document = try BrowserArticleCaptureDecoder.decode(captured, context: try context)
        XCTAssertEqual(document.contentType, .thread)
    }

    func testArticleCoverCardIsNeverArchivedAsAPost() async throws {
        let html = postPage(tweet(
            id: postID,
            text: "",
            extra: "<a href=\"/i/article/2095455845823971411\"><div data-testid=\"article-cover-image\"></div>文章封面</a>"
        ))
        let result = try await run(html, flags: "window.__markxAllowPostFallback = true;\n")
        XCTAssertTrue(result.hasPrefix("__X_CAPTURE_DIAGNOSTIC__:"), result)
    }
}

@MainActor
private final class FixtureLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
