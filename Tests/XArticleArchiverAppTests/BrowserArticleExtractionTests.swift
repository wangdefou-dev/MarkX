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

        let webView = makeFixtureWebView()
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation
        try await navigation.load(
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

    func testDoesNotTreatVideoMediaLinksAsMissingArticleImages() async throws {
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
            <h1 data-testid="twitter-article-title">正文图与视频链接</h1>
            <div data-testid="videoPlayer">
              <a href="/writer/status/\(postID)/media/201"></a>
              <a href="/writer/status/\(postID)/media/202"></a>
              <a href="/writer/status/\(postID)/media/203"></a>
            </div>
            <div data-testid="longformRichTextComponent">
              <div class="longform-unstyled" data-block="true">
                <span data-text="true">配图说明</span>
              </div>
              <section data-block="true">
                <a href="/writer/status/\(postID)/media/101"><img src="https://pbs.twimg.com/media/a?format=jpg&amp;name=medium"></a>
              </section>
              <section data-block="true">
                <a href="/writer/status/\(postID)/media/102"><img src="https://pbs.twimg.com/media/b?format=jpg&amp;name=medium"></a>
              </section>
            </div>
          </div>
        </article>
        """

        let payload = try await extractPayload(html: html, postID: postID)
        XCTAssertEqual(payload.unsupportedBlockCount, 0)
        XCTAssertEqual(payload.blocks.compactMap(\.imageID), ["101", "102"])
        XCTAssertEqual(payload.blocks.filter { $0.kind == .image }.count, 2)
    }

    func testEmbeddedStatusCardWithoutTweetTestIDIsQuotedLink() async throws {
        let postID = "2075260912223830183"
        let quotedID = "2075260912223830001"
        let html = """
        <!doctype html>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'none'">
        <article>
          <a href="/writer">测试作者</a>
          <time datetime="2026-09-02T03:04:00.000Z"></time>
          <div data-testid="twitterArticleReadView">
            <h1 data-testid="twitter-article-title">含引用推文</h1>
            <div data-testid="longformRichTextComponent">
              <div class="longform-unstyled" data-block="true">
                <span data-text="true">引用前</span>
              </div>
              <section data-block="true">
                <div>
                  <a href="/quoted_writer/status/\(quotedID)">
                    <div>quoted_writer</div>
                    <div>被引用的普通推文</div>
                  </a>
                </div>
              </section>
              <section data-block="true"><div><div></div></div></section>
              <div class="longform-unstyled" data-block="true">
                <span data-text="true">引用后</span>
              </div>
            </div>
          </div>
        </article>
        """

        let payload = try await extractPayload(html: html, postID: postID)
        XCTAssertEqual(payload.unsupportedBlockCount, 0)
        XCTAssertEqual(payload.blocks.map(\.kind), [.paragraph, .embeddedPost, .paragraph])
        XCTAssertEqual(
            payload.blocks[1].text,
            "https://x.com/quoted_writer/status/\(quotedID)"
        )

        let creator = Creator(xUserID: "writer-id", username: "writer", displayName: "测试作者")
        let link = try XCTUnwrap(XArticleURLParser.parse("https://x.com/writer/status/\(postID)").first)
        let document = try BrowserArticleCaptureDecoder.decode(
            payload,
            context: BrowserArticleCaptureContext(
                link: link,
                creator: creator,
                expectedPlainText: "引用前\n引用后"
            )
        )
        XCTAssertEqual(document.blocks.map(\.kind), [.paragraph, .embeddedPost, .paragraph])
        XCTAssertEqual(document.blocks[1].text, "https://x.com/quoted_writer/status/\(quotedID)")
    }

    func testExtractsPaidPartnershipFromArticleChrome() async throws {
        let postID = "2049065078843195696"
        let html = """
        <!doctype html>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'none'">
        <article>
          <a href="/writer">测试作者</a>
          <div data-testid="paidPartnership">Paid partnership</div>
          <time datetime="2026-09-02T03:04:00.000Z"></time>
          <div data-testid="twitterArticleReadView">
            <h1 data-testid="twitter-article-title">官方付费合作</h1>
            <div data-testid="longformRichTextComponent">
              <div class="longform-unstyled" data-block="true">
                <span data-text="true">第一段</span>
              </div>
            </div>
          </div>
        </article>
        """

        let payload = try await extractPayload(html: html, postID: postID)
        XCTAssertTrue(payload.isPaidPartnership)
        XCTAssertTrue((payload.disclosureChromeText ?? "").localizedCaseInsensitiveContains("Paid partnership"))
        XCTAssertTrue((payload.disclosureTestIDs ?? []).contains("paidPartnership"))
        XCTAssertFalse((payload.disclosureChromeText ?? "").contains("第一段"))

        let creator = Creator(xUserID: "writer-id", username: "writer", displayName: "测试作者")
        let link = try XCTUnwrap(XArticleURLParser.parse("https://x.com/writer/status/\(postID)").first)
        let document = try BrowserArticleCaptureDecoder.decode(
            payload,
            context: BrowserArticleCaptureContext(link: link, creator: creator)
        )
        XCTAssertEqual(document.isPaidPartnership, true)
    }

    func testDisclosureScriptReadsPaidPartnershipWithoutWaitingForBodyImages() async throws {
        let postID = "2049065078843195696"
        let html = """
        <!doctype html>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'none'">
        <article>
          <a href="/writer">测试作者</a>
          <div data-testid="paidPartnership">Paid partnership</div>
          <time datetime="2026-09-02T03:04:00.000Z"></time>
          <div data-testid="twitterArticleReadView">
            <h1 data-testid="twitter-article-title">官方付费合作</h1>
            <div data-testid="longformRichTextComponent">
              <div class="longform-unstyled" data-block="true">
                <span data-text="true">第一段</span>
              </div>
            </div>
          </div>
        </article>
        """

        let webView = makeFixtureWebView()
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation
        try await navigation.load(
            html,
            in: webView,
            baseURL: URL(string: "https://x.com/writer/status/\(postID)")!
        )
        let raw = try await webView.evaluateJavaScript(BrowserArticleDisclosureScript.source)
        let json = try XCTUnwrap(raw as? String)
        XCTAssertFalse(json.hasPrefix("__X_CAPTURE_ERROR__:"), json)
        let payload = try JSONDecoder().decode(BrowserArticleCapturePayload.self, from: Data(json.utf8))
        XCTAssertTrue(payload.isPaidPartnership)
        XCTAssertTrue((payload.disclosureTestIDs ?? []).contains("paidPartnership"))
        XCTAssertTrue(payload.blocks.isEmpty)
    }

    func testDoesNotTreatBodyMentionsAsPaidPartnership() async throws {
        let postID = "2049065078843195696"
        let html = """
        <!doctype html>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'none'">
        <article>
          <a href="/writer">测试作者</a>
          <time datetime="2026-09-02T03:04:00.000Z"></time>
          <div data-testid="twitterArticleReadView">
            <h1 data-testid="twitter-article-title">政策说明</h1>
            <div data-testid="longformRichTextComponent">
              <div class="longform-unstyled" data-block="true">
                <span data-text="true">这篇文章讲解 Paid partnership 政策和付费合作开关。</span>
              </div>
            </div>
          </div>
        </article>
        """

        let payload = try await extractPayload(html: html, postID: postID)
        XCTAssertFalse(payload.isPaidPartnership)
        XCTAssertFalse((payload.disclosureChromeText ?? "").localizedCaseInsensitiveContains("Paid partnership"))
    }

    private func extractPayload(html: String, postID: String) async throws -> BrowserArticleCapturePayload {
        let webView = makeFixtureWebView()
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation
        try await navigation.load(
            html,
            in: webView,
            baseURL: URL(string: "https://x.com/writer/status/\(postID)")!
        )
        let raw = try await webView.evaluateJavaScript(BrowserArticleExtractionScript.source)
        let json = try XCTUnwrap(raw as? String)
        XCTAssertFalse(json.hasPrefix("__X_CAPTURE_ERROR__:"), json)
        return try JSONDecoder().decode(BrowserArticleCapturePayload.self, from: Data(json.utf8))
    }
}

@MainActor
final class BlockedProfileArticleListGateTests: XCTestCase {
    func testClicksViewPostsInsideTheArticlesColumn() async throws {
        let html = """
        <!doctype html>
        <main>
          <div data-testid="primaryColumn">
            <h1>@zjp1997720 is blocked</h1>
            <p>Are you sure you want to view these posts? Viewing posts won't unblock @zjp1997720.</p>
            <a id="learn-more" href="https://support.x.com/articles/117063">Learn more</a>
            <a id="analytics" href="/zjp1997720/status/1/analytics">View post analytics</a>
            <button type="button" id="view-posts" onclick="this.dataset.clicked='yes'">
              <span>View</span> <span>posts</span>
            </button>
          </div>
          <aside>
            <button type="button" id="sidebar" onclick="this.dataset.clicked='yes'">View posts</button>
          </aside>
        </main>
        """

        let webView = try await load(html)
        let raw = try await webView.evaluateJavaScript(BlockedProfileArticleListGate.revealScript)
        XCTAssertEqual(raw as? String, BlockedProfileArticleListGate.clickedResult)
        let clicked = try await webView.evaluateJavaScript("document.getElementById('view-posts').dataset.clicked")
        let sidebar = try await webView.evaluateJavaScript("document.getElementById('sidebar').dataset.clicked || ''")
        XCTAssertEqual(clicked as? String, "yes")
        XCTAssertEqual(sidebar as? String, "")
    }

    func testClicksChineseViewPostsWhenTheColumnHasNoTestID() async throws {
        let html = """
        <!doctype html>
        <main>
          <button type="button" id="view-posts" onclick="this.dataset.clicked='yes'">查看帖子</button>
        </main>
        """

        let webView = try await load(html)
        let raw = try await webView.evaluateJavaScript(BlockedProfileArticleListGate.revealScript)
        XCTAssertEqual(raw as? String, BlockedProfileArticleListGate.clickedResult)
        let clicked = try await webView.evaluateJavaScript("document.getElementById('view-posts').dataset.clicked")
        XCTAssertEqual(clicked as? String, "yes")
    }

    func testClicksAPlainViewPostsLabelAndKeepsWaitingWhileTheGateIsVisible() async throws {
        let html = """
        <!doctype html>
        <main>
          <div data-testid="primaryColumn">
            <h1>@zjp1997720 is blocked</h1>
            <p>Viewing posts won't unblock @zjp1997720.</p>
            <div id="view-posts" onclick="this.dataset.clicked='yes'">查看帖子</div>
          </div>
        </main>
        """

        let webView = try await load(html)
        let clicked = try await webView.evaluateJavaScript(BlockedProfileArticleListGate.revealScript)
        XCTAssertEqual(clicked as? String, BlockedProfileArticleListGate.clickedResult)
        let marker = try await webView.evaluateJavaScript("document.getElementById('view-posts').dataset.clicked")
        XCTAssertEqual(marker as? String, "yes")
        let blocking = try await webView.evaluateJavaScript(BlockedProfileArticleListGate.blockingScript)
        XCTAssertEqual(blocking as? String, "blocking")
    }

    func testClicksTheChineseBlockedProfileButton() async throws {
        let html = """
        <!doctype html>
        <main>
          <div data-testid="primaryColumn">
            <h1>你已屏蔽 @zjp1997720</h1>
            <button type="button" id="view-profile" onclick="this.dataset.clicked='yes'">是，查看个人资料</button>
          </div>
        </main>
        """

        let webView = try await load(html)
        let raw = try await webView.evaluateJavaScript(BlockedProfileArticleListGate.revealScript)
        XCTAssertEqual(raw as? String, BlockedProfileArticleListGate.clickedResult)
        let clicked = try await webView.evaluateJavaScript("document.getElementById('view-profile').dataset.clicked")
        XCTAssertEqual(clicked as? String, "yes")
        let blocking = try await webView.evaluateJavaScript(BlockedProfileArticleListGate.blockingScript)
        XCTAssertEqual(blocking as? String, "blocking")
    }

    func testLeavesThePageAloneWhenTheListIsAlreadyVisible() async throws {
        let html = """
        <!doctype html>
        <main>
          <a id="analytics" href="/zjp1997720/status/1/analytics">View post analytics</a>
          <article data-testid="tweet"><a href="/zjp1997720/status/1">一篇长文</a></article>
        </main>
        """

        let webView = try await load(html)
        let raw = try await webView.evaluateJavaScript(BlockedProfileArticleListGate.revealScript)
        XCTAssertEqual(raw as? String, BlockedProfileArticleListGate.absentResult)
    }

    func testReadsAnArticleCoverCardAndDoesNotCallAShortPageEmpty() async throws {
        let cardHTML = """
        <!doctype html>
        <main>
          <div data-testid="primaryColumn">
            <div data-testid="articleCard">
              <a href="/i/article/2106000255464701953"><div dir="auto">玉伯的长文</div></a>
            </div>
          </div>
        </main>
        """
        let card = try await readList(cardHTML, handle: "lifesinger")
        XCTAssertEqual(card.items.map(\.url), ["https://x.com/i/article/2106000255464701953"])
        XCTAssertEqual(card.items.map(\.title), ["玉伯的长文"])
        XCTAssertFalse(card.explicitEmpty)
        XCTAssertTrue(card.atBottom)

        let shellHTML = """
        <!doctype html>
        <main>
          <div data-testid="primaryColumn">
            <h1>@lifesinger</h1>
          </div>
        </main>
        """
        let shell = try await readList(shellHTML, handle: "lifesinger")
        XCTAssertTrue(shell.items.isEmpty)
        XCTAssertFalse(shell.explicitEmpty)

        let errorHTML = """
        <!doctype html>
        <main>
          <div data-testid="primaryColumn">
            <h1>Something went wrong</h1>
            <button type="button">Try again</button>
          </div>
        </main>
        """
        let error = try await readList(errorHTML, handle: "lifesinger")
        XCTAssertTrue(error.items.isEmpty)
        XCTAssertFalse(error.explicitEmpty)

        let emptyHTML = """
        <!doctype html>
        <main>
          <div data-testid="primaryColumn">
            <div data-testid="emptyState">@lifesinger hasn't posted</div>
          </div>
        </main>
        """
        let empty = try await readList(emptyHTML, handle: "lifesinger")
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertTrue(empty.explicitEmpty)
    }

    func testScrollsAnInnerArticlesTimelineAndKeepsStatusIdsDistinctFromArticleIds() async throws {
        let html = """
        <!doctype html>
        <main>
          <div data-testid="primaryColumn" style="height: 500px; overflow: hidden;">
            <div id="timeline" style="height: 280px; overflow-y: auto;">
              <div data-testid="cellInnerDiv" style="height: 200px;">
                <a href="/lifesinger/status/2106002684075745332"><div dir="auto">第一篇</div></a>
                <a href="/i/article/2106000255464701953">文章</a>
              </div>
              <div data-testid="cellInnerDiv" style="height: 200px;">
                <a href="/lifesinger/status/2104053180476604479"><div dir="auto">第二篇</div></a>
              </div>
              <div data-testid="cellInnerDiv" style="height: 200px;">
                <a href="/lifesinger/status/2104186950295110037"><div dir="auto">第三篇</div></a>
              </div>
              <div data-testid="cellInnerDiv" style="height: 200px;">
                <a href="/i/article/2103732446374359147"><div dir="auto">第四篇只有文章链接</div></a>
              </div>
              <div data-testid="cellInnerDiv" style="height: 200px;">
                <a href="/lifesinger/status/2102764610109813192"><div dir="auto">第五篇</div></a>
              </div>
              <div id="spacer" style="height: 4000px;"></div>
            </div>
          </div>
        </main>
        """
        let webView = try await load(html, baseURL: URL(string: "https://x.com/lifesinger/articles")!)
        let before = try await readList(in: webView, handle: "lifesinger")
        XCTAssertFalse(before.atBottom)
        XCTAssertEqual(before.items.map(\.url), [
            "https://x.com/lifesinger/status/2106002684075745332",
            "https://x.com/lifesinger/status/2104053180476604479",
            "https://x.com/lifesinger/status/2104186950295110037",
            "https://x.com/i/article/2103732446374359147",
            "https://x.com/lifesinger/status/2102764610109813192"
        ])
        XCTAssertEqual(before.items.map(\.title), ["第一篇", "第二篇", "第三篇", "第四篇只有文章链接", "第五篇"])
        let beforeTopValue = try await webView.evaluateJavaScript("document.getElementById('timeline').scrollTop")
        let beforeTop = try XCTUnwrap(beforeTopValue as? NSNumber).doubleValue
        XCTAssertEqual(beforeTop, 0, accuracy: 0.1)
        _ = try await webView.evaluateJavaScript(CreatorArticlesListExtractor.scrollScript)
        let afterTopValue = try await webView.evaluateJavaScript("document.getElementById('timeline').scrollTop")
        let afterTop = try XCTUnwrap(afterTopValue as? NSNumber).doubleValue
        XCTAssertGreaterThan(afterTop, 200)
        let after = try await readList(in: webView, handle: "lifesinger")
        XCTAssertFalse(after.atBottom)
    }

    private func readList(_ html: String, handle: String) async throws -> CreatorArticleListProbe {
        let webView = try await load(html, baseURL: URL(string: "https://x.com/\(handle)/articles")!)
        return try await readList(in: webView, handle: handle)
    }

    private func readList(in webView: WKWebView, handle: String) async throws -> CreatorArticleListProbe {
        let raw = try await webView.callAsyncJavaScript(
            CreatorArticlesListExtractor.script,
            arguments: ["expectedHandle": handle],
            in: nil,
            contentWorld: .page
        )
        let json = try XCTUnwrap(raw as? String)
        XCTAssertFalse(json.hasPrefix("__X_ARTICLE_LIST_ERROR__:"), json)
        return try JSONDecoder().decode(CreatorArticleListProbe.self, from: Data(json.utf8))
    }

    private func load(_ html: String) async throws -> WKWebView {
        try await load(html, baseURL: URL(string: "https://x.com/zjp1997720/articles")!)
    }

    private func load(_ html: String, baseURL: URL) async throws -> WKWebView {
        let webView = makeFixtureWebView(frame: CGRect(x: 0, y: 0, width: 1100, height: 800))
        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation
        try await navigation.load(html, in: webView, baseURL: baseURL)
        return webView
    }
}

private struct CreatorArticleListProbe: Decodable {
    struct Item: Decodable {
        var title: String
        var url: String
    }

    var items: [Item]
    var explicitEmpty: Bool
    var atBottom: Bool
    var scrollHeight: Int
    var scrollTop: Int
}

@MainActor
private func makeFixtureWebView(frame: CGRect = .zero) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    return WKWebView(frame: frame, configuration: configuration)
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private enum NavigationError: LocalizedError {
        case couldNotStart
        case webContentProcessTerminated
        case timedOut

        var errorDescription: String? {
            switch self {
            case .couldNotStart: "WebKit did not start loading the HTML fixture."
            case .webContentProcessTerminated: "The WebKit content process terminated while loading the HTML fixture."
            case .timedOut: "WebKit did not finish loading the HTML fixture within 10 seconds."
            }
        }
    }

    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ html: String, in webView: WKWebView, baseURL: URL) async throws {
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            finish(.failure(NavigationError.timedOut))
            webView.stopLoading()
        }
        defer { timeout.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if webView.loadHTMLString(html, baseURL: baseURL) == nil {
                finish(.failure(NavigationError.couldNotStart))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(NavigationError.webContentProcessTerminated))
    }

    private func finish(_ result: Result<Void, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
