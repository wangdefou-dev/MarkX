import WebKit
import XCTest
@testable import XArticleArchiverApp
@testable import XArticleArchiverCore

@MainActor
final class BrowserArticleExtractionTests: XCTestCase {
    func testExtractsEveryCarouselImageAndPreservesUnavailableEmbeddedPost() async throws {
        let postID = "2049065078843195696"
        let html = """
        <!doctype html>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'none'">
        <script>
          Object.defineProperty(HTMLImageElement.prototype, 'complete', {get: () => true});
          Object.defineProperty(HTMLImageElement.prototype, 'naturalWidth', {get: () => 1200});
        </script>
        <article>
          <a href="/writer">测试作者</a>
          <time datetime="2026-09-02T03:04:00.000Z"></time>
          <div data-testid="twitterArticleReadView">
            <h1 data-testid="twitter-article-title">轮播与不可用引用</h1>
            <div data-testid="longformRichTextComponent">
              <div class="longform-unstyled" data-block="true">
                <span data-text="true">第一段</span>
              </div>
              <section data-block="true">
                <nav data-testid="ScrollSnap-SwipeableList">
                  <a href="/writer/article/\(postID)/media/101"><div><img src="https://pbs.twimg.com/media/a?format=jpg&amp;name=medium"></div></a>
                  <a href="/writer/article/\(postID)/media/102"><div><img src="https://pbs.twimg.com/media/b?format=jpg&amp;name=medium"></div></a>
                  <a href="/writer/article/\(postID)/media/103"><div><img src="https://pbs.twimg.com/media/c?format=jpg&amp;name=medium"></div></a>
                  <a href="/writer/article/\(postID)/media/104"><div><img src="https://pbs.twimg.com/media/d?format=jpg&amp;name=medium"></div></a>
                </nav>
              </section>
              <section data-block="true">
                <div data-testid="tombstone"><article>Post unavailable</article></div>
              </section>
              <div class="longform-unstyled" data-block="true">
                <span data-text="true">最后一段</span>
              </div>
            </div>
          </div>
        </article>
        """

        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation
        await navigation.load(
            html,
            in: webView,
            baseURL: URL(string: "https://x.com/writer/status/\(postID)")!
        )

        let raw = try await webView.evaluateJavaScript(BrowserArticleExtractionScript.source)
        let json = try XCTUnwrap(raw as? String)
        XCTAssertFalse(json.hasPrefix("__X_CAPTURE_ERROR__:"), json)
        let payload = try JSONDecoder().decode(BrowserArticleCapturePayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.blocks.map(\.kind), [
            .paragraph,
            .image, .image, .image, .image,
            .unavailableEmbeddedPost,
            .paragraph
        ])
        XCTAssertEqual(
            payload.blocks.compactMap(\.imageID),
            ["101", "102", "103", "104"]
        )

        let creator = Creator(xUserID: "writer-id", username: "writer", displayName: "测试作者")
        let link = try XCTUnwrap(XArticleURLParser.parse("https://x.com/writer/status/\(postID)").first)
        let document = try BrowserArticleCaptureDecoder.decode(
            payload,
            context: BrowserArticleCaptureContext(
                link: link,
                creator: creator,
                expectedPlainText: "第一段\n最后一段"
            )
        )
        XCTAssertEqual(document.media.map(\.id), ["101", "102", "103", "104"])
        XCTAssertEqual(document.blocks.map(\.kind), [
            .paragraph,
            .image, .image, .image, .image,
            .embeddedPost,
            .paragraph
        ])
        XCTAssertEqual(document.blocks[5].text, "Post unavailable")
        XCTAssertEqual(document.warnings, ["文章包含 1 条已不可用的引用内容，已按页面原位置保留占位说明"])
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume()
        continuation = nil
    }
}
