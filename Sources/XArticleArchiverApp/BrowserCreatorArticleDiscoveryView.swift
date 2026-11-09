import SwiftUI
import WebKit
import XArticleArchiverCore

/// X hides a blocked profile's Articles behind a confirmation whose only
/// action is a "View posts" button. Clicking it reveals the list in place
/// and does not unblock the account.
enum BlockedProfileArticleListGate {
    static let clickedResult = "clicked"
    static let absentResult = "absent"

    static let revealScript = #"""
    (() => {
      const labels = new Set([
        "view posts",
        "查看帖子",
        "查看推文",
        "是，查看个人资料",
        "是,查看个人资料",
        "yes, view profile"
      ]);
      const roots = [
        document.querySelector('[data-testid="primaryColumn"]'),
        document.querySelector("main"),
        document.body
      ].filter(Boolean);
      const normalize = (el) => (el.innerText || el.textContent || "").replace(/\s+/g, " ").trim().toLowerCase();
      const click = (el) => {
        el.scrollIntoView({block: "center"});
        el.click();
        return "clicked";
      };
      const seen = new Set();
      const scan = (selector) => {
        for (const root of roots) {
          for (const el of root.querySelectorAll(selector)) {
            if (seen.has(el)) continue;
            seen.add(el);
            if (!labels.has(normalize(el))) continue;
            const childMatches = [...el.querySelectorAll('button, [role="button"], a, div, span')]
              .some((child) => labels.has(normalize(child)));
            if (childMatches) continue;
            return click(el);
          }
        }
        return null;
      };
      return scan('button, [role="button"]') || scan('a, div, span') || "absent";
    })()
    """#

    /// The gate is still covering the list even when its control is not a
    /// button we managed to click. An empty scan must not settle while this
    /// text is on screen.
    static let blockingScript = #"""
    (() => {
      const root = document.querySelector('[data-testid="primaryColumn"]')
        || document.querySelector("main")
        || document.body;
      if (!root) return "absent";
      const text = (root.innerText || root.textContent || "").replace(/\s+/g, " ").toLowerCase();
      const hints = [
        "view posts",
        "查看帖子",
        "查看推文",
        "是，查看个人资料",
        "是,查看个人资料",
        "yes, view profile",
        "is blocked",
        "won't unblock",
        "已被屏蔽",
        "不会取消屏蔽",
        "不会解除屏蔽",
        "查看这些帖子",
        "view these posts"
      ];
      return hints.some((hint) => text.includes(hint)) ? "blocking" : "absent";
    })()
    """#
}

private struct CreatorArticleListSnapshot: Decodable {
    struct Item: Decodable {
        var title: String
        var url: String
    }

    var items: [Item]
    var atBottom: Bool
    var isLoadingMore: Bool
    var explicitEmpty: Bool
    var scrollHeight: Int
    var scrollTop: Int
}

@MainActor
private final class BrowserCreatorArticleDiscoveryController: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isLoading = false
    @Published var isDiscovering = false
    @Published var isImportingBrowserSession = false
    @Published var pageStatus = "正在准备博主文章列表…"
    @Published var currentURL: URL?
    @Published var discoveredItems: [CreatorArticleListItem] = []
    @Published var discoveredCount = 0
    @Published private(set) var webViewEpoch = 0

    private(set) var webView: WKWebView
    private var currentListURL: URL?
    private var creatorsSinceRecycle = 0
    private var hasImportedBrowserSession = false

    override init() {
        webView = IsolatedXWebView.make()
        super.init()
        webView.navigationDelegate = self
    }

    private func recycleWebView() {
        IsolatedXWebView.retire(webView)
        webView = IsolatedXWebView.make()
        webView.navigationDelegate = self
        hasImportedBrowserSession = false
        creatorsSinceRecycle = 0
        currentListURL = nil
        webViewEpoch += 1
    }

    func load(_ request: CreatorArticleDiscoveryRequest) {
        currentListURL = request.pageURL
        pageStatus = "正在打开 @\(request.username) 的 Articles 列表…"
        webView.load(URLRequest(
            url: request.pageURL,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 60
        ))
    }

    func reload() {
        pageStatus = "正在重新加载文章列表…"
        webView.reload()
    }

    func importBrowserSession() async throws -> ChromeXSession {
        guard !isImportingBrowserSession else {
            throw BrowserArticleCaptureError.pageNotReady("正在从本机浏览器导入登录状态")
        }
        isImportingBrowserSession = true
        pageStatus = "正在读取本机浏览器中的 X 登录状态…"
        defer { isImportingBrowserSession = false }

        let session = try await Task.detached(priority: .userInitiated) {
            try BrowserSessionAccess.readActiveSession()
        }.value
        try Task.checkCancellation()
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in session.cookies {
            await cookieStore.setCookie(cookie)
        }
        hasImportedBrowserSession = true
        pageStatus = "已导入 \(session.sourceDescription)登录状态，正在刷新 Articles 列表…"
        if let currentListURL {
            webView.load(URLRequest(
                url: currentListURL,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 60
            ))
        } else {
            webView.reload()
        }
        return session
    }

    func discoverAutomatically(_ request: CreatorArticleDiscoveryRequest) async throws -> CreatorArticleDiscoveryResult {
        guard !isDiscovering else {
            throw BrowserArticleCaptureError.pageNotReady("文章列表发现正在进行")
        }
        isDiscovering = true
        discoveredItems = []
        discoveredCount = 0
        defer { isDiscovering = false }

        if BrowserProcessBudget.shouldRecycleDiscovery(creatorsSinceRecycle: creatorsSinceRecycle) {
            pageStatus = "正在释放浏览器内存后继续读取列表…"
            recycleWebView()
            await Task.yield()
        }
        load(request)
        if !hasImportedBrowserSession, await BrowserSessionAccess.hasLocalBrowserData() {
            let session = try await importBrowserSession()
            pageStatus = "已使用 \(session.sourceDescription)登录状态，正在只读取 Articles 列表…"
        } else if !hasImportedBrowserSession {
            pageStatus = "未发现可读取的本机浏览器配置，正在尝试读取公开 Articles 列表…"
        }
        creatorsSinceRecycle += 1
        try await Task.sleep(for: .milliseconds(700))
        try await returnToArticlesListIfNeeded(request)

        var orderedItems: [CreatorArticleListItem] = []
        var seenPostIDs = Set<String>()
        var unchangedAtBottom = 0
        var gateSettlePolls = 0
        var lastScrollExtent = -1
        var stableWhileSpinner = 0
        var lastReason = "X Articles 列表仍在加载"

        // The list is virtualized: cards that leave the viewport may disappear
        // from the DOM. Accumulate each visible batch before scrolling again.
        // Bound lack of progress, rather than the total length of a creator's
        // history. A growing list must not be cut off after 320 scrolls.
        var progressBudget = CreatorArticleScanProgressBudget()
        while !progressBudget.exhausted {
            progressBudget.beginPoll()
            try Task.checkCancellation()
            if !isLoading {
                if await revealBlockedArticleListIfNeeded() {
                    unchangedAtBottom = 0
                    gateSettlePolls = 10
                    pageStatus = "@\(request.username) 的文章列表被屏蔽确认挡住了，已点击 View posts，正在继续读取…"
                    try await Task.sleep(for: .milliseconds(900))
                    continue
                }
                if orderedItems.isEmpty, await blockedListStillCoveringArticles() {
                    unchangedAtBottom = 0
                    pageStatus = "@\(request.username) 的屏蔽确认还在，先不把文章总数记成 0…"
                    try await Task.sleep(for: .milliseconds(750))
                    continue
                }
                do {
                    let snapshot = try await readSnapshot(expectedHandle: request.username)
                    let before = orderedItems.count
                    for rawItem in snapshot.items {
                        guard let link = XArticleURLParser.parseCreatorArticlesPageLinks(
                            [rawItem.url],
                            expectedUsername: request.username
                        ).first else { continue }
                        guard seenPostIDs.insert(link.postID).inserted else { continue }
                        let cleanedTitle = rawItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        orderedItems.append(CreatorArticleListItem(
                            link: link,
                            title: cleanedTitle.isEmpty ? "X Article · \(link.postID)" : cleanedTitle
                        ))
                    }
                    let selectedCount = CreatorArticleDiscoveryPolicy.selectedCount(
                        discoveredCount: orderedItems.count,
                        maximumArticles: request.maximumArticles
                    )
                    discoveredCount = orderedItems.count
                    discoveredItems = request.countOnly
                        ? []
                        : Array(orderedItems.prefix(selectedCount))

                    if CreatorArticleDiscoveryPolicy.shouldStopAtRequestedLimit(
                        discoveredCount: orderedItems.count,
                        maximumArticles: request.maximumArticles,
                        resolvesTotalCount: request.resolvesTotalCount
                    ) {
                        pageStatus = "已从 @\(request.username) Articles 列表找到 \(selectedCount) 篇；X API 调用为 0"
                        return CreatorArticleDiscoveryResult(
                            items: request.countOnly ? [] : discoveredItems,
                            knownArticleCount: nil
                        )
                    }

                    let gained = orderedItems.count - before
                    if gained > 0 { progressBudget.foundNewItems() }
                    let waitingForRevealedList = gateSettlePolls > 0
                    if waitingForRevealedList {
                        gateSettlePolls -= 1
                    }
                    let extentChanged = lastScrollExtent >= 0 && snapshot.scrollHeight != lastScrollExtent
                    let quietAtBottom = snapshot.atBottom && gained == 0 && !extentChanged && !waitingForRevealedList
                    if quietAtBottom && snapshot.isLoadingMore {
                        stableWhileSpinner += 1
                    } else if !quietAtBottom {
                        stableWhileSpinner = 0
                    }
                    let loadingBlocksSettle = CreatorArticleListSettlePolicy.loadingBlocksSettle(
                        isLoadingMore: snapshot.isLoadingMore,
                        stableWhileSpinner: stableWhileSpinner
                    )
                    if quietAtBottom && !loadingBlocksSettle {
                        unchangedAtBottom += 1
                    } else {
                        unchangedAtBottom = 0
                    }
                    lastScrollExtent = snapshot.scrollHeight

                    pageStatus = orderedItems.isEmpty
                        ? (waitingForRevealedList
                            ? "已点击 View posts，正在等待 @\(request.username) 的文章卡片…"
                            : "已打开 Articles 列表，正在等待文章卡片…")
                        : "已找到 \(orderedItems.count) 篇 Article，正在向下检查更多…X API 调用为 0"

                    let pageReportsEmpty = snapshot.explicitEmpty && orderedItems.isEmpty
                    if CreatorArticleListSettlePolicy.isSettled(
                        itemCount: orderedItems.count,
                        unchangedAtBottom: unchangedAtBottom,
                        gateVisible: waitingForRevealedList,
                        pageReportsEmpty: pageReportsEmpty
                    ) {
                        let confirmedCount = orderedItems.isEmpty ? nil : orderedItems.count
                        let confirmedEmpty = pageReportsEmpty
                        pageStatus = request.countOnly
                            ? (confirmedCount.map { "@\(request.username) 线上共 \($0) 篇 Article，正在保存总数；不会下载文章" }
                                ?? "@\(request.username) 的 Articles 列表已核对，线上是 0 篇")
                            : confirmedEmpty
                                ? "@\(request.username) 的 Articles 列表已核对，线上是 0 篇"
                                : "@\(request.username) 线上已确认 \(orderedItems.count) 篇 Article，将处理\(CreatorArticleDiscoveryPolicy.rangeDescription(maximumArticles: request.maximumArticles))；X API 调用为 0"
                        return CreatorArticleDiscoveryResult(
                            items: request.countOnly ? [] : discoveredItems,
                            knownArticleCount: confirmedCount,
                            confirmedEmpty: confirmedEmpty
                        )
                    }
                    try await scrollForMore()
                } catch BrowserArticleCaptureError.pageNotReady(let detail) {
                    lastReason = detail
                    pageStatus = "已使用浏览器登录状态，正在等待 Articles 列表…"
                }
            }
            try await Task.sleep(for: .milliseconds(750))
        }

        if !orderedItems.isEmpty {
            let selectedCount = CreatorArticleDiscoveryPolicy.selectedCount(
                discoveredCount: orderedItems.count,
                maximumArticles: request.maximumArticles
            )
            return CreatorArticleDiscoveryResult(
                items: request.countOnly ? [] : Array(orderedItems.prefix(selectedCount)),
                knownArticleCount: nil,
                isComplete: false
            )
        }
        throw BrowserArticleCaptureError.pageNotReady(lastReason)
    }

    private func readSnapshot(expectedHandle: String) async throws -> CreatorArticleListSnapshot {
        let raw = try await webView.callAsyncJavaScript(
            CreatorArticlesListExtractor.script,
            arguments: ["expectedHandle": expectedHandle],
            in: nil,
            contentWorld: .page
        )
        guard let json = raw as? String else {
            throw BrowserArticleCaptureError.pageNotReady("文章列表返回了无法识别的结果")
        }
        if json.hasPrefix(Self.errorPrefix) {
            throw BrowserArticleCaptureError.pageNotReady(String(json.dropFirst(Self.errorPrefix.count)))
        }
        return try JSONDecoder().decode(CreatorArticleListSnapshot.self, from: Data(json.utf8))
    }

    private func scrollForMore() async throws {
        _ = try await webView.evaluateJavaScript(CreatorArticlesListExtractor.scrollScript)
    }

    private func revealBlockedArticleListIfNeeded() async -> Bool {
        do {
            let raw = try await webView.evaluateJavaScript(BlockedProfileArticleListGate.revealScript)
            return (raw as? String) == BlockedProfileArticleListGate.clickedResult
        } catch {
            return false
        }
    }

    private func blockedListStillCoveringArticles() async -> Bool {
        do {
            let raw = try await webView.evaluateJavaScript(BlockedProfileArticleListGate.blockingScript)
            return (raw as? String) == "blocking"
        } catch {
            return false
        }
    }

    private func returnToArticlesListIfNeeded(_ request: CreatorArticleDiscoveryRequest) async throws {
        for _ in 0..<8 {
            try Task.checkCancellation()
            if let pathname = try await webView.evaluateJavaScript("location.pathname") as? String,
               XArticleURLParser.isCreatorArticlesListPath(pathname, username: request.username) {
                return
            }
            pageStatus = "当前不在 @\(request.username) 的 Articles 列表，正在重新打开…"
            load(request)
            try await Task.sleep(for: .milliseconds(900))
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        currentURL = webView.url
        pageStatus = "正在加载 X Articles 列表…"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url
        pageStatus = isDiscovering
            ? "列表已加载，正在提取 Article 链接…"
            : "列表已加载"
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        pageStatus = "Articles 列表加载失败：\(error.localizedDescription)"
    }

    private static let errorPrefix = "__X_ARTICLE_LIST_ERROR__:"
}

/// Reads the logged-in Articles tab. Cover cards are not always tweets, and a
/// short page with no cards is not an empty archive unless X says so.
enum CreatorArticlesListExtractor {
    /// Shared by the snapshot and the scroll step. The Articles timeline is
    /// often an inner overflow container; the window can look finished while
    /// that container is still on the first screen.
    static let timelineHelpers = #"""
    const cardSelector = '[data-testid="cellInnerDiv"], article[data-testid="tweet"], [data-testid="articleCard"], [data-testid="articlePreview"]';
    function articlesColumn() {
      return document.querySelector('[data-testid="primaryColumn"]')
        || document.querySelector("main")
        || document.body;
    }
    function isDocumentScroller(node) {
      return !!node && (node === document.scrollingElement || node === document.documentElement || node === document.body);
    }
    function nodeMetrics(node) {
      const isDocument = isDocumentScroller(node);
      const scrollTop = isDocument ? (window.scrollY || (document.scrollingElement && document.scrollingElement.scrollTop) || 0) : (node.scrollTop || 0);
      const clientHeight = isDocument ? window.innerHeight : (node.clientHeight || 0);
      const scrollHeight = isDocument
        ? ((document.scrollingElement && document.scrollingElement.scrollHeight) || node.scrollHeight || 0)
        : (node.scrollHeight || 0);
      const overflow = scrollHeight - clientHeight;
      const atBottom = overflow <= 220 || (scrollTop + clientHeight >= scrollHeight - 220);
      return { scrollTop, clientHeight, scrollHeight, overflow, atBottom };
    }
    function timelineScrollers(column) {
      const nodes = [];
      const seen = new Set();
      const consider = (node) => {
        if (!node || seen.has(node)) return;
        const isDocument = isDocumentScroller(node);
        const metrics = nodeMetrics(node);
        if (metrics.overflow <= 40) return;
        if (!isDocument && metrics.clientHeight < 160) return;
        if (!isDocument && !node.querySelector(cardSelector)) return;
        const overflowY = isDocument ? "auto" : ((getComputedStyle(node).overflowY || "") + " " + (getComputedStyle(node).overflow || ""));
        if (!isDocument && !/auto|scroll|overlay|hidden/.test(overflowY)) return;
        if (!isDocument && /hidden/.test(overflowY) && !/auto|scroll|overlay/.test(overflowY)) {
          const before = node.scrollTop || 0;
          node.scrollTop = before + 1;
          const moved = (node.scrollTop || 0) > before;
          node.scrollTop = before;
          if (!moved) return;
        }
        seen.add(node);
        nodes.push(node);
      };
      const anchor = (column && column.querySelector(cardSelector)) || column;
      let node = anchor;
      while (node && node !== document) {
        consider(node);
        node = node.parentElement;
      }
      consider(document.scrollingElement || document.documentElement);
      if (column) {
        for (const candidate of column.querySelectorAll("div, section")) consider(candidate);
      }
      return nodes;
    }
    function timelinePosition(column) {
      const nodes = timelineScrollers(column);
      if (!nodes.length) return { atBottom: true, scrollHeight: 0, scrollTop: 0 };
      const metrics = nodes.map(nodeMetrics);
      return {
        atBottom: metrics.every((item) => item.atBottom),
        scrollHeight: Math.round(metrics.reduce((sum, item) => sum + item.scrollHeight, 0)),
        scrollTop: Math.round(metrics.reduce((sum, item) => sum + item.scrollTop, 0))
      };
    }
    function scrollTimeline(column) {
      const nodes = timelineScrollers(column);
      const cards = column ? [...column.querySelectorAll(cardSelector)] : [];
      const last = cards[cards.length - 1];
      if (last && last.scrollIntoView) last.scrollIntoView({ block: "end", inline: "nearest" });
      const deltaFor = (node) => Math.max(520, (nodeMetrics(node).clientHeight || window.innerHeight) * 0.85);
      for (const node of nodes) {
        const delta = deltaFor(node);
        if (isDocumentScroller(node)) {
          const next = (window.scrollY || 0) + delta;
          window.scrollTo(0, next);
          if (document.scrollingElement) document.scrollingElement.scrollTop = next;
        } else {
          node.scrollTop = (node.scrollTop || 0) + delta;
        }
        node.dispatchEvent(new Event("scroll", { bubbles: true }));
      }
      const wheelTarget = nodes[0] || column || window;
      wheelTarget.dispatchEvent(new WheelEvent("wheel", { deltaY: 900, bubbles: true, cancelable: true }));
      const showMoreLabels = new Set(["show more", "see more", "load more", "查看更多", "显示更多", "加载更多"]);
      const normalize = (el) => (el.innerText || el.textContent || "").replace(/\s+/g, " ").trim().toLowerCase();
      if (column) {
        for (const el of column.querySelectorAll('button, [role="button"]')) {
          if (!showMoreLabels.has(normalize(el))) continue;
          if (el.closest(cardSelector)) continue;
          el.click();
          break;
        }
      }
    }
    """#

    static let script = timelineHelpers + #"""

    const ERROR = "__X_ARTICLE_LIST_ERROR__:";
    const normalizedHandle = String(expectedHandle || '').replace(/^@/, '').toLowerCase();
    const path = String(location.pathname || '').replace(/\/+$/, '') || '/';
    const pathMatch = path.match(/^(?:\/[a-z]{2}(?:-[A-Za-z]{2})?)?\/([A-Za-z0-9_]{1,15})\/articles$/i);
    if (!pathMatch || pathMatch[1].toLowerCase() !== normalizedHandle) {
      return ERROR + "当前页面不是目标博主的 Articles 列表。";
    }

    const column = articlesColumn();
    const anchors = column
      ? [...column.querySelectorAll('a[href*="/status/"], a[href*="/article/"]')]
      : [];
    const grouped = new Map();
    const cardOf = new WeakMap();
    let nextCard = 1;
    for (const anchor of anchors) {
      let resolved;
      try { resolved = new URL(anchor.getAttribute('href') || '', location.href); }
      catch (_) { continue; }
      const host = resolved.hostname.toLowerCase();
      if (host !== 'x.com' && !host.endsWith('.x.com') && host !== 'twitter.com' && !host.endsWith('.twitter.com')) continue;
      const match = resolved.pathname.match(/^\/(?:i|([A-Za-z0-9_]{1,15}))\/(?:status|article)\/(\d{1,19})(?:\/|$)/i);
      if (!match || /\/analytics(?:\/|$)/i.test(resolved.pathname)) continue;
      const hrefHandle = (match[1] || normalizedHandle).toLowerCase();
      if (hrefHandle !== 'i' && hrefHandle !== normalizedHandle) continue;
      const titleRoot = anchor.closest('[data-testid="articleCard"], [data-testid="articlePreview"], article[data-testid="tweet"], [data-testid="cellInnerDiv"]') || anchor;
      let cardKey = cardOf.get(titleRoot);
      if (!cardKey) {
        cardKey = "c" + (nextCard++);
        cardOf.set(titleRoot, cardKey);
      }
      let entry = grouped.get(cardKey);
      if (!entry) {
        entry = { title: "", statusID: "", articlePath: "" };
        grouped.set(cardKey, entry);
      }
      const title = [...titleRoot.querySelectorAll('div[dir="auto"]')]
        .map(node => (node.innerText || '').trim())
        .find(Boolean)
        || (anchor.innerText || '').replace(/\s+/g, ' ').trim();
      if (title && !entry.title) entry.title = title;
      if (/\/status\//i.test(resolved.pathname)) {
        if (!entry.statusID) entry.statusID = match[2];
      } else if (!entry.articlePath) {
        entry.articlePath = resolved.pathname;
      }
    }
    const items = [];
    const seen = new Set();
    for (const entry of grouped.values()) {
      const url = entry.statusID
        ? `https://x.com/${normalizedHandle}/status/${entry.statusID}`
        : (entry.articlePath ? `https://x.com${entry.articlePath}` : "");
      const identity = entry.statusID || entry.articlePath;
      if (!url || !identity || seen.has(identity)) continue;
      seen.add(identity);
      items.push({
        title: entry.title || `X Article · ${entry.statusID || entry.articlePath.split('/').pop()}`,
        url
      });
    }

    const position = timelinePosition(column);
    const atBottom = position.atBottom;
    const scrollHeight = position.scrollHeight;
    const scrollTop = position.scrollTop;
    // X also renders unrelated loading indicators in the recommendations
    // sidebar. Only a spinner inside the main timeline can mean that the
    // Articles list itself is still fetching another page.
    const primaryColumn = document.querySelector('[data-testid="primaryColumn"]');
    const isLoadingMore = !!primaryColumn?.querySelector('[role="progressbar"]');
    const columnText = (column?.innerText || "").replace(/\s+/g, " ").toLowerCase();
    const reportsError = [
      "something went wrong",
      "try again",
      "出错了",
      "请重试",
      "this account doesn't exist",
      "account suspended",
      "账号不存在",
      "账号已被冻结"
    ].some((hint) => columnText.includes(hint));
    const reportsEmptyCopy = [
      "hasn't posted",
      "hasn't written",
      "has not posted",
      "no articles yet",
      "hasn't published",
      "还没有发布",
      "尚未发布",
      "没有发布任何",
      "还没有文章",
      "暂无文章"
    ].some((hint) => columnText.includes(hint));
    const hasEmptyState = !!column?.querySelector('[data-testid="emptyState"], [data-testid="empty_state"]');
    const explicitEmpty = items.length === 0 && !reportsError && (hasEmptyState || reportsEmptyCopy);
    return JSON.stringify({items, atBottom, isLoadingMore, explicitEmpty, scrollHeight, scrollTop});
    """#

    static let scrollScript = "(() => {\n" + timelineHelpers + #"""

      scrollTimeline(articlesColumn());
      return true;
    })()
    """#
}

struct BrowserCreatorArticleDiscoveryView: View {
    @EnvironmentObject private var model: AppViewModel
    @StateObject private var controller = BrowserCreatorArticleDiscoveryController()

    private var request: CreatorArticleDiscoveryRequest? {
        model.currentCreatorArticleDiscoveryRequest
    }


    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Divider()
            statusCard.padding(.horizontal, 20).padding(.vertical, 16)
            discoveredArticleList.padding(.horizontal, 20).padding(.bottom, 16)
            footer
        }
        .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
        .background(MarkXInterface.canvas)
        .background {
            // WebKit must stay mounted at a normal viewport size so X keeps
            // rendering its virtualized Articles timeline. The opaque app
            // surface above it makes the browser entirely invisible to users.
            ZStack {
                BrowserWebView(webView: controller.webView)
                    .id(controller.webViewEpoch)
                    .frame(width: 1_100, height: 800)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .clipped()
        .task(id: request?.id) {
            guard let request else { return }
            do {
                let result = try await controller.discoverAutomatically(request)
                try Task.checkCancellation()
                await model.completeCreatorArticleDiscovery(result, for: request)
            } catch is CancellationError {
                return
            } catch {
                let failedRequest = request
                let failedError = error
                Task { @MainActor in
                    await model.creatorArticleDiscoveryFailed(failedError, for: failedRequest)
                }
                controller.pageStatus = "这位博主的列表没读到，继续下一位…"
            }
        }
        .interactiveDismissDisabled(controller.isDiscovering)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 20)).foregroundStyle(.secondary)
                .frame(width: 34, height: 34).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(request.map { "正在检查 @\($0.username)" } ?? "正在查找博主文章").font(.system(size: 17, weight: .semibold)).lineLimit(2)
                Text(model.isRefreshingCreatorCounts ? "完整扫描列表，更新线上文章总数。" : "新发现的文章会自动进入保存队列。").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Text("博主 \(currentCreatorNumber) / \(creatorCount)").font(.system(size: 12, weight: .medium)).monospacedDigit()
                Text("X API · 0").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.pageStatus).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text("已识别 \(controller.discoveredCount) 篇文章")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14).markxSurface()
    }

    private var discoveredArticleList: some View {
        Group {
            if model.isRefreshingCreatorCounts {
                ContentUnavailableView {
                    Label("正在统计线上文章", systemImage: "number")
                } description: {
                    Text("已扫描 \(controller.discoveredCount) 篇 Articles 卡片；不会下载文章")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.discoveredItems.isEmpty {
                ContentUnavailableView {
                    Label("正在查找文章", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("识别到的标题和链接会逐条显示在这里")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(controller.discoveredItems.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top, spacing: 11) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.12))
                                    .frame(width: 28, height: 28)
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(2)
                                Text(item.sourceURLText)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minHeight: 200, maxHeight: .infinity)
        .background(MarkXInterface.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var footer: some View {
        MarkXFooter(note: "隐藏窗口后，任务仍会在后台继续") {
            Button("停止") { model.closeCreatorArticleDiscovery() }
                .help("安全停止本次任务，已完成内容保留")
            Button("隐藏到后台") { model.hideDownloadProgressWindow() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction)
                .help("隐藏窗口并继续后台任务")
        }
    }

    private var creatorCount: Int {
        max(model.creatorArticleDiscoveryRequests.count, 1)
    }

    private var currentCreatorNumber: Int {
        min(model.creatorArticleDiscoveryIndex + 1, creatorCount)
    }
}
