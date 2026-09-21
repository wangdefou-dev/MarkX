import SwiftUI
import WebKit
import XArticleArchiverCore

private struct CreatorArticleListSnapshot: Decodable {
    struct Item: Decodable {
        var title: String
        var url: String
    }

    var items: [Item]
    var atBottom: Bool
    var isLoadingMore: Bool
}

@MainActor
private final class BrowserCreatorArticleDiscoveryController: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var isLoading = false
    @Published var isDiscovering = false
    @Published var isImportingChromeSession = false
    @Published var pageStatus = "正在准备博主文章列表…"
    @Published var currentURL: URL?
    @Published var discoveredItems: [CreatorArticleListItem] = []
    @Published var discoveredCount = 0

    let webView: WKWebView
    private var currentListURL: URL?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsMagnification = true
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

    func importChromeSession() async throws -> ChromeXSession {
        guard !isImportingChromeSession else {
            throw BrowserArticleCaptureError.pageNotReady("正在从 Chrome 导入登录状态")
        }
        isImportingChromeSession = true
        pageStatus = "正在读取 Chrome 中的 X 登录状态…"
        defer { isImportingChromeSession = false }

        let session = try await Task.detached(priority: .userInitiated) {
            try ChromeXSessionReader.readActiveSession()
        }.value
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in session.cookies {
            await cookieStore.setCookie(cookie)
        }
        pageStatus = "已导入 Chrome「\(session.profileName)」登录状态，正在刷新 Articles 列表…"
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

        load(request)
        if ChromeXSessionReader.hasLocalChromeProfile() {
            let session = try await importChromeSession()
            pageStatus = "已使用 Chrome「\(session.profileName)」登录状态，正在只读取 Articles 列表…"
        } else {
            pageStatus = "未找到 Chrome 配置，正在尝试读取公开 Articles 列表…"
        }
        try await Task.sleep(for: .milliseconds(700))
        try await returnToArticlesListIfNeeded(request)

        var orderedItems: [CreatorArticleListItem] = []
        var seenPostIDs = Set<String>()
        var unchangedAtBottom = 0
        var lastReason = "X Articles 列表仍在加载"

        // The list is virtualized: cards that leave the viewport may disappear
        // from the DOM. Accumulate each visible batch before scrolling again.
        for _ in 0..<240 {
            try Task.checkCancellation()
            if !isLoading {
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
                    if snapshot.atBottom && !snapshot.isLoadingMore && gained == 0 {
                        unchangedAtBottom += 1
                    } else {
                        unchangedAtBottom = 0
                    }

                    pageStatus = orderedItems.isEmpty
                        ? "已打开 Articles 列表，正在等待文章卡片…"
                        : "已找到 \(orderedItems.count) 篇 Article，正在向下检查更多…X API 调用为 0"

                    if unchangedAtBottom >= 5 {
                        pageStatus = request.countOnly
                            ? "@\(request.username) 线上共 \(orderedItems.count) 篇 Article，正在保存总数；不会下载文章"
                            : "@\(request.username) 线上共 \(orderedItems.count) 篇 Article，将处理最近 \(selectedCount) 篇；X API 调用为 0"
                        return CreatorArticleDiscoveryResult(
                            items: request.countOnly ? [] : discoveredItems,
                            knownArticleCount: orderedItems.count
                        )
                    }
                    try await scrollForMore()
                } catch BrowserArticleCaptureError.pageNotReady(let detail) {
                    lastReason = detail
                    pageStatus = "已使用 Chrome 登录状态，正在等待 Articles 列表…"
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
                knownArticleCount: nil
            )
        }
        throw BrowserArticleCaptureError.pageNotReady(lastReason)
    }

    private func readSnapshot(expectedHandle: String) async throws -> CreatorArticleListSnapshot {
        let raw = try await webView.callAsyncJavaScript(
            Self.discoveryScript,
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
        _ = try await webView.evaluateJavaScript(Self.scrollScript)
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

    private static let discoveryScript = #"""
    const ERROR = "__X_ARTICLE_LIST_ERROR__:";
    const normalizedHandle = String(expectedHandle || '').replace(/^@/, '').toLowerCase();
    const path = String(location.pathname || '').replace(/\/+$/, '') || '/';
    const pathMatch = path.match(/^(?:\/[a-z]{2}(?:-[A-Za-z]{2})?)?\/([A-Za-z0-9_]{1,15})\/articles$/i);
    if (!pathMatch || pathMatch[1].toLowerCase() !== normalizedHandle) {
      return ERROR + "当前页面不是目标博主的 Articles 列表。";
    }

    const cards = [
      ...document.querySelectorAll('article[data-testid="tweet"]'),
      ...document.querySelectorAll('[data-testid="cellInnerDiv"]')
    ];
    const items = [];
    const seen = new Set();
    for (const card of cards) {
      const anchors = [...card.querySelectorAll('a[href*="/status/"], a[href*="/article/"]')];
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
        if (seen.has(match[2])) continue;
        seen.add(match[2]);
        const title = [...card.querySelectorAll('div[dir="auto"]')]
          .map(node => (node.innerText || '').trim())
          .find(Boolean) || `X Article · ${match[2]}`;
        items.push({
          title,
          url: `https://x.com/${normalizedHandle}/status/${match[2]}`
        });
      }
    }

    const root = document.scrollingElement || document.documentElement;
    const atBottom = root.scrollTop + window.innerHeight >= root.scrollHeight - 220;
    // X also renders unrelated loading indicators in the recommendations
    // sidebar. Only a spinner inside the main timeline can mean that the
    // Articles list itself is still fetching another page.
    const primaryColumn = document.querySelector('[data-testid="primaryColumn"]');
    const isLoadingMore = !!primaryColumn?.querySelector('[role="progressbar"]');
    return JSON.stringify({items, atBottom, isLoadingMore});
    """#

    private static let scrollScript = #"""
    (() => {
      const cards = [...document.querySelectorAll('article[data-testid="tweet"]')];
      if (cards.length) cards[cards.length - 1].scrollIntoView({block:'end'});
      window.scrollBy({top: Math.max(420, window.innerHeight * 0.82), behavior:'auto'});
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
        VStack(spacing: 18) {
            header
            statusCard
            discoveredArticleList
            footer
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            // WebKit must stay mounted at a normal viewport size so X keeps
            // rendering its virtualized Articles timeline. The opaque app
            // surface above it makes the browser entirely invisible to users.
            ZStack {
                BrowserWebView(webView: controller.webView)
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
                model.creatorArticleDiscoveryFailed(error)
                controller.pageStatus = "文章列表自动发现未完成，可重新加载后再试"
            }
        }
        .interactiveDismissDisabled(controller.isDiscovering)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(request.map {
                    model.isRefreshingCreatorCounts
                        ? "正在刷新 @\($0.username) 的线上文章总数"
                        : model.isSyncingTrackedCreators
                        ? "正在同步 @\($0.username) 的文章"
                        : "正在获取 @\($0.username) 的文章"
                } ?? (model.isRefreshingCreatorCounts
                      ? "正在刷新线上文章总数"
                      : model.isSyncingTrackedCreators ? "正在同步博主文章" : "正在获取博主文章"))
                    .font(.title3.weight(.semibold))
                Text(model.isRefreshingCreatorCounts
                     ? "完整扫描 Articles 列表，只更新总数，不下载文章"
                     : model.isSyncingTrackedCreators
                         ? (model.activeSyncResolvesTotalCount
                             ? "先获取完整 Articles 列表总数，再处理选定范围；已有完整归档会自动跳过"
                             : "只读取每位博主最近文章；已有完整归档会自动跳过")
                         : (request?.resolvesTotalCount == true
                             ? "先获取完整 Articles 列表总数，再处理选定范围；浏览器页面不会显示"
                             : "只读取最近文章，线上总数可稍后手动刷新；浏览器页面不会显示"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Label("X API 0 次", systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Text("博主 \(currentCreatorNumber) / \(creatorCount)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.pageStatus)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Text(model.isRefreshingCreatorCounts
                     ? "已扫描 \(controller.discoveredCount) 篇文章卡片"
                     : model.isSyncingTrackedCreators
                         ? "已检查并识别 \(controller.discoveredItems.count) 篇文章标题和链接"
                         : "已识别 \(controller.discoveredItems.count) 篇文章标题和链接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if ChromeXSessionReader.hasLocalChromeProfile() {
                Label("Chrome 登录态已启用", systemImage: "key.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.1), in: Capsule())
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.12))
        }
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
            }
        }
        .frame(minHeight: 350)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash.fill")
                .foregroundStyle(.secondary)
            Text(model.isRefreshingCreatorCounts
                 ? "完整扫描只用于更新线上总数，不会下载文章。"
                 : model.isSyncingTrackedCreators
                     ? "同步在后台自动运行，已有完整归档会跳过，完成后统一显示同步结果。"
                     : "采集过程在后台自动运行，完成后会统一显示下载结果。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("隐藏到后台") { model.hideDownloadProgressWindow() }
                .help("隐藏进度窗口，文章发现会继续在后台执行")
            Button("停止") { model.closeCreatorArticleDiscovery() }
                .keyboardShortcut(.cancelAction)
                .help(model.isRefreshingCreatorCounts
                      ? "停止线上文章总数刷新"
                      : model.isSyncingTrackedCreators
                          ? "停止本次同步；已经完成的本地归档保留"
                          : "停止当前博主的 Articles 列表发现；已发现的标题和链接保留")
        }
    }

    private var creatorCount: Int {
        max(model.creatorArticleDiscoveryRequests.count, 1)
    }

    private var currentCreatorNumber: Int {
        min(model.creatorArticleDiscoveryIndex + 1, creatorCount)
    }
}
