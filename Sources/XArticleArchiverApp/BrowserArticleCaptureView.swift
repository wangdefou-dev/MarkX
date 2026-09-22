import AppKit
import SwiftUI
import WebKit
import XArticleArchiverCore

@MainActor
private final class BrowserArticleCaptureController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var isLoading = false
    @Published var isCapturing = false
    @Published var isImportingChromeSession = false
    @Published var isAutomaticCaptureRunning = false
    @Published var pageStatus = "正在准备 X 页面…"
    @Published var currentURL: URL?
    @Published var popupWebView: WKWebView?
    @Published private(set) var webViewEpoch = 0

    private(set) var webView: WKWebView
    private var pagesSinceRecycle = 0
    private var hasImportedChromeSession = false

    var visibleWebView: WKWebView { popupWebView ?? webView }
    var canGoBack: Bool { visibleWebView.canGoBack }

    override init() {
        webView = IsolatedXWebView.make(allowPopups: true)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = nil
    }

    private func recycleWebView() {
        IsolatedXWebView.retire(webView)
        closeLoginWindow(reloadArticle: false)
        webView = IsolatedXWebView.make(allowPopups: true)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.customUserAgent = nil
        hasImportedChromeSession = false
        pagesSinceRecycle = 0
        currentArticleURL = nil
        webViewEpoch += 1
    }

    func load(_ request: BrowserCaptureRequest) {
        let canonical = URL(string: "https://x.com/\(request.link.username)/status/\(request.link.postID)")!
        currentArticleURL = canonical
        if webView.url != canonical {
            closeLoginWindow(reloadArticle: false)
            pageStatus = "正在加载《\(request.displayTitle)》…"
            webView.load(URLRequest(url: canonical, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 60))
        }
    }

    func reload() {
        pageStatus = "正在重新加载…"
        visibleWebView.reload()
    }

    func goBack() {
        if visibleWebView.canGoBack { visibleWebView.goBack() }
    }

    func closeLoginWindow(reloadArticle: Bool = true) {
        guard let popupWebView else { return }
        popupWebView.stopLoading()
        popupWebView.navigationDelegate = nil
        popupWebView.uiDelegate = nil
        self.popupWebView = nil
        if reloadArticle {
            pageStatus = "登录窗口已关闭，正在刷新文章页…"
            webView.reload()
        }
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
        closeLoginWindow(reloadArticle: false)
        hasImportedChromeSession = true
        pageStatus = "已导入 Chrome「\(session.profileName)」的 X 登录状态"
        return session
    }

    func capture(
        updateStatus: Bool = true,
        expectedCreatorHandle: String? = nil
    ) async throws -> BrowserArticleCapturePayload {
        isCapturing = true
        if updateStatus {
            pageStatus = "正在按页面顺序读取段落、列表、表格、代码和图片…"
        }
        defer { isCapturing = false }
        let raw = try await webView.evaluateJavaScript(BrowserArticleExtractionScript.source)
        guard let json = raw as? String else {
            throw BrowserArticleCaptureError.pageNotReady("页面返回了无法识别的结果")
        }
        if json.hasPrefix(Self.errorPrefix) {
            throw BrowserArticleCaptureError.pageNotReady(String(json.dropFirst(Self.errorPrefix.count)))
        }
        if json.hasPrefix(Self.diagnosticPrefix) {
            let diagnosticJSON = String(json.dropFirst(Self.diagnosticPrefix.count))
            guard let diagnostic = try? JSONDecoder().decode(
                BrowserArticlePageDiagnostic.self,
                from: Data(diagnosticJSON.utf8)
            ) else {
                throw BrowserArticleCaptureError.pageNotReady("页面访问状态无法识别，请重新加载后再试")
            }
            if BrowserArticleAccessGateDetector.isSubscriptionRequired(diagnostic) {
                let creatorHandle = HandleParser.normalize(diagnostic.authorHandle ?? "")
                    ?? HandleParser.normalize(expectedCreatorHandle ?? "")
                throw BrowserArticleCaptureError.subscriptionRequired(creatorHandle: creatorHandle)
            }
            throw BrowserArticleCaptureError.pageNotReady(
                "未找到完整的 X Article 正文。请确认已登录、当前链接是 Article，并等待页面加载完成。"
            )
        }
        let payload = try JSONDecoder().decode(BrowserArticleCapturePayload.self, from: Data(json.utf8))
        let imageCount = payload.blocks.filter { $0.kind == .image }.count
        let codeCount = payload.blocks.filter { $0.kind == .code }.count
        let tableCount = payload.blocks.filter { $0.kind == .table }.count
        let embeddedMediaCount = payload.blocks.filter { $0.kind == .embeddedMedia }.count
        if updateStatus {
            pageStatus = "已读取 \(payload.blocks.count) 个排版块、\(imageCount) 张图片、\(tableCount) 个表格、\(codeCount) 个代码块、\(embeddedMediaCount) 个嵌入媒体"
        }
        return payload
    }

    /// Default capture path: copy the already-authenticated X cookies from
    /// Chrome, wait until the rendered Article structure is stable, then hand
    /// the verified payload to the archive pipeline without asking the user to
    /// sign in or press another save button.
    func captureAutomatically(_ request: BrowserCaptureRequest) async throws -> BrowserArticleCapturePayload {
        guard !isAutomaticCaptureRunning else {
            throw BrowserArticleCaptureError.pageNotReady("自动采集正在进行")
        }
        isAutomaticCaptureRunning = true
        defer { isAutomaticCaptureRunning = false }

        if request.disclosureOnly {
            return try await captureDisclosure(request)
        }

        if BrowserProcessBudget.shouldRecycleCapture(pagesSinceRecycle: pagesSinceRecycle) {
            pageStatus = "正在释放浏览器内存后继续保存…"
            recycleWebView()
        }
        var didJustImportCookies = false
        if !hasImportedChromeSession, ChromeXSessionReader.hasLocalChromeProfile() {
            let session = try await importChromeSession()
            pageStatus = "已自动使用 Chrome「\(session.profileName)」登录状态，正在等待完整排版…"
            didJustImportCookies = true
        } else if !hasImportedChromeSession {
            pageStatus = "未找到 Chrome 配置，正在尝试读取公开文章…"
        }
        load(request)
        pagesSinceRecycle += 1
        if ArticleCaptureStabilityPolicy.shouldSettleAfterLoad(didJustImportCookies: didJustImportCookies) {
            try await Task.sleep(nanoseconds: ArticleCaptureStabilityPolicy.cookieImportSettleNanoseconds)
        }

        var previousPayload: BrowserArticleCapturePayload?
        var stableMatches = 0
        var lastNotReadyReason = "X Article 页面仍在加载"

        for _ in 0..<ArticleCaptureStabilityPolicy.maxPolls {
            try Task.checkCancellation()
            if !isLoading {
                do {
                    let payload = try await capture(
                        updateStatus: false,
                        expectedCreatorHandle: request.creator.username
                    )
                    let complete = ArticleCaptureStabilityPolicy.isStructurallyComplete(payload)
                    if complete, payload == previousPayload {
                        stableMatches += 1
                    } else {
                        previousPayload = payload
                        stableMatches = 0
                    }
                    let required = ArticleCaptureStabilityPolicy.requiredConsecutiveMatches(
                        blockCount: payload.blocks.count,
                        structurallyComplete: complete
                    )
                    let imageCount = payload.blocks.filter { $0.kind == .image }.count
                    if complete, stableMatches >= required {
                        pageStatus = "完整排版已稳定，正在自动保存…"
                        return payload
                    }
                    pageStatus = complete
                        ? (payload.blocks.count == 1
                            ? "已读取单块长文，正在确认内容不再变化…"
                            : "已读取 \(payload.blocks.count) 个排版块、\(imageCount) 张图片，正在确认内容完整…")
                        : "正在等待图片和正文加载完整…"
                } catch BrowserArticleCaptureError.pageNotReady(let detail) {
                    lastNotReadyReason = detail
                    previousPayload = nil
                    stableMatches = 0
                    pageStatus = "已使用 Chrome 登录状态，正在等待正文完整加载…"
                }
            }
            try await Task.sleep(
                nanoseconds: ArticleCaptureStabilityPolicy.pollNanoseconds(isLoading: isLoading)
            )
        }

        throw BrowserArticleCaptureError.pageNotReady(lastNotReadyReason)
    }

    private func captureDisclosure(_ request: BrowserCaptureRequest) async throws -> BrowserArticleCapturePayload {
        if !hasImportedChromeSession, ChromeXSessionReader.hasLocalChromeProfile() {
            let session = try await importChromeSession()
            pageStatus = "已自动使用 Chrome「\(session.profileName)」登录状态，正在核对商单内容…"
        } else if !hasImportedChromeSession {
            pageStatus = "未找到 Chrome 配置，正在尝试核对公开文章的商单标记…"
        }
        load(request)
        try await Task.sleep(for: .milliseconds(700))

        var lastNotReadyReason = "X Article 页面仍在加载"
        for _ in 0..<40 {
            try Task.checkCancellation()
            if !isLoading {
                do {
                    let payload = try await captureDisclosurePayload()
                    pageStatus = payload.isPaidPartnership
                        ? "已识别商单内容标记，不重复下载正文和媒体"
                        : "已核对，不是商单内容，不重复下载正文和媒体"
                    return payload
                } catch BrowserArticleCaptureError.pageNotReady(let detail) {
                    lastNotReadyReason = detail
                    pageStatus = "正在等待文章页加载，以便核对商单内容…"
                }
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw BrowserArticleCaptureError.pageNotReady(lastNotReadyReason)
    }

    private func captureDisclosurePayload() async throws -> BrowserArticleCapturePayload {
        let raw = try await webView.evaluateJavaScript(BrowserArticleDisclosureScript.source)
        guard let json = raw as? String else {
            throw BrowserArticleCaptureError.pageNotReady("页面返回了无法识别的结果")
        }
        if json.hasPrefix(Self.errorPrefix) {
            throw BrowserArticleCaptureError.pageNotReady(String(json.dropFirst(Self.errorPrefix.count)))
        }
        return try JSONDecoder().decode(BrowserArticleCapturePayload.self, from: Data(json.utf8))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        currentURL = webView.url
        pageStatus = webView === popupWebView
            ? "正在加载 X 登录窗口…"
            : "正在加载 X Article…"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url
        if webView === popupWebView {
            pageStatus = "请在独立窗口完成登录；应用不会保存密码或验证码。"
        } else {
            pageStatus = isAutomaticCaptureRunning
                ? "页面已加载，正在自动检查完整排版…"
                : "页面已加载，可重新导入 Chrome 登录状态或立即保存。"
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        pageStatus = "页面加载失败：\(error.localizedDescription)"
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if let popupWebView {
            popupWebView.load(navigationAction.request)
            return nil
        }
        // Keep OAuth/login popups in the same ephemeral session as the article
        // page so a completed login is immediately visible without persisting
        // a duplicate set of browser cookies on disk.
        configuration.websiteDataStore = self.webView.configuration.websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.allowsMagnification = true
        popupWebView = popup
        pageStatus = "已打开独立登录窗口…"
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popupWebView else { return }
        closeLoginWindow(reloadArticle: true)
    }

    private static let errorPrefix = "__X_CAPTURE_ERROR__:"
    private static let diagnosticPrefix = "__X_CAPTURE_DIAGNOSTIC__:"
    private var currentArticleURL: URL?

    /// X currently renders published Articles as DraftJS blocks below
    /// `longformRichTextComponent`. We intentionally read only those explicit
    /// blocks, rather than broad page text, so replies/navigation never leak
    /// into the archive. Unknown block types fail closed in Core.
    fileprivate static let extractionScript = #"""
    (() => {
      const ERROR = "__X_CAPTURE_ERROR__:";
      const DIAGNOSTIC = "__X_CAPTURE_DIAGNOSTIC__:";
      const articleView = document.querySelector('[data-testid="twitterArticleReadView"]');
      const richRoot = articleView?.querySelector('[data-testid="longformRichTextComponent"]')
        || articleView?.querySelector('[data-testid="twitterArticleRichTextView"]');
      if (!articleView || !richRoot) {
        const diagnosticRoot = document.querySelector('main') || document.body;
        const authorHandle = location.pathname
          .match(/^\/([A-Za-z0-9_]{1,15})\/(?:status|article)\//i)?.[1] || null;
        const visibleText = (diagnosticRoot?.innerText || '')
          .replace(/\s+/g, ' ')
          .trim()
          .slice(0, 12000);
        const linkURLs = [...(diagnosticRoot?.querySelectorAll('a[href]') || [])]
          .map(anchor => {
            try { return new URL(anchor.getAttribute('href') || '', location.href).href; }
            catch (_) { return null; }
          })
          .filter(Boolean)
          .slice(0, 300);
        return DIAGNOSTIC + JSON.stringify({ visibleText, linkURLs, authorHandle });
      }

      const pathMatch = location.pathname.match(/\/(?:status|article)\/(\d{1,19})(?:\/|$)/i);
      if (!pathMatch) return ERROR + "当前地址中没有可识别的 Article Post ID。";

      const titleNode = articleView.querySelector('[data-testid="twitter-article-title"]');
      const title = (titleNode?.innerText || '').trim();
      if (!title) return ERROR + "文章标题还没有加载。";

      const outerArticle = articleView.parentElement?.closest('article') || articleView;
      const timeNode = outerArticle.querySelector('time[datetime]');
      const profileLinks = [...outerArticle.querySelectorAll('a[href]')]
        .map(a => ({a, m:(a.getAttribute('href') || '').match(/^\/([A-Za-z0-9_]{1,15})\/?$/)}))
        .filter(x => x.m);
      const authorHandle = profileLinks[0]?.m?.[1] || null;
      const authorName = profileLinks
        .map(x => (x.a.innerText || '').trim())
        .find(x => x && !x.startsWith('@')) || null;

      const collectDisclosureSignals = (root, ignoredRoots) => {
        const ignored = node => ignoredRoots.some(ignoredRoot => ignoredRoot && ignoredRoot.contains(node));
        const hidden = [];
        const hide = node => {
          if (!node) return;
          hidden.push([node, node.style.display]);
          node.style.display = 'none';
        };
        ignoredRoots.forEach(hide);
        let chromeText = '';
        let linkURLs = [];
        let testIDs = [];
        try {
          const ariaLabels = [...root.querySelectorAll('[aria-label]')]
            .filter(node => !ignored(node))
            .map(node => node.getAttribute('aria-label') || '')
            .filter(Boolean);
          chromeText = [(root.innerText || ''), ...ariaLabels]
            .join('\n')
            .replace(/\u00a0/g, ' ')
            .trim()
            .slice(0, 4000);
          linkURLs = [...root.querySelectorAll('a[href]')]
            .filter(anchor => !ignored(anchor))
            .map(anchor => {
              try { return new URL(anchor.getAttribute('href') || '', location.href).href; }
              catch (_) { return null; }
            })
            .filter(Boolean)
            .slice(0, 80);
          testIDs = [...root.querySelectorAll('[data-testid]')]
            .filter(node => !ignored(node))
            .map(node => node.getAttribute('data-testid') || '')
            .filter(Boolean)
            .slice(0, 80);
        } finally {
          hidden.forEach(([node, display]) => { node.style.display = display; });
        }
        return { chromeText, linkURLs, testIDs };
      };
      const disclosure = collectDisclosureSignals(outerArticle, [richRoot, titleNode]);

      const absoluteURL = value => {
        try { return new URL(value, location.href).href; } catch (_) { return null; }
      };
      const canonicalXContentURL = value => {
        try {
          const parsed = new URL(value, location.href);
          const host = parsed.hostname.toLowerCase().replace(/^(?:www\.|mobile\.)/, '');
          if (host !== 'x.com' && host !== 'twitter.com') return null;
          const parts = parsed.pathname.split('/').filter(Boolean);
          const isHandleRoute = parts.length >= 3
            && /^[A-Za-z0-9_]{1,15}$/.test(parts[0])
            && (parts[1] === 'status' || parts[1] === 'article')
            && /^\d{1,19}$/.test(parts[2]);
          const isIdentityRoute = parts.length >= 3
            && parts[0] === 'i'
            && (parts[1] === 'status' || parts[1] === 'article')
            && /^\d{1,19}$/.test(parts[2]);
          if (!isHandleRoute && !isIdentityRoute) return null;
          return `https://x.com/${parts.slice(0, 3).join('/')}`;
        } catch (_) {
          return null;
        }
      };
      const mediaID = image => {
        const href = image.closest('a[href*="/media/"]')?.getAttribute('href') || '';
        return href.match(/\/media\/(\d+)/)?.[1] || null;
      };
      const currentArticleMediaID = anchor => {
        try {
          const parsed = new URL(anchor.getAttribute('href') || '', location.href);
          const host = parsed.hostname.toLowerCase().replace(/^(?:www\.|mobile\.)/, '');
          if (host !== 'x.com' && host !== 'twitter.com') return null;
          const match = parsed.pathname.match(
            /^\/(?:[A-Za-z0-9_]{1,15}|i)\/(?:article|status)\/(\d{1,19})\/media\/(\d{1,19})\/?$/i
          );
          return match && match[1] === pathMatch[1] ? match[2] : null;
        } catch (_) {
          return null;
        }
      };
      const articleMediaURL = image => {
        const value = absoluteURL(image.currentSrc || image.src || '');
        if (!value) return null;
        try {
          const parsed = new URL(value);
          // X also renders avatars, emoji and interface artwork as <img>
          // elements. Only pbs.twimg.com/media/ belongs to the Article body.
          if (parsed.hostname.toLowerCase() !== 'pbs.twimg.com') return null;
          if (!parsed.pathname.startsWith('/media/')) return null;
          return value;
        } catch (_) {
          return null;
        }
      };
      const imageBlock = image => {
        const imageURL = articleMediaURL(image);
        if (!imageURL) return null;
        return {
          kind: 'image', text: '', level: 0, depth: 0, styles: [], links: [],
          imageURL,
          imageID: mediaID(image),
          altText: image.getAttribute('alt') || null,
          language: null
        };
      };
      const belongsToQuotedCard = element => {
        const card = element.closest('article, [data-testid="tweet"], [data-testid="card.wrapper"]');
        return Boolean(
          card &&
          card !== articleView &&
          card !== outerArticle &&
          richRoot.contains(card)
        );
      };
      const isVideoChromeAnchor = anchor => Boolean(
        anchor.closest('video, audio, [data-testid="videoPlayer"], [data-testid="videoComponent"], [data-testid="previewInterstitial"]')
      );
      const pbsMediaURLFromNode = element => {
        const seen = new WeakSet();
        let remaining = 8000;
        let found = null;
        const visit = (value, depth) => {
          if (found || value == null || --remaining < 0 || depth > 8) return;
          if (typeof value === 'string') {
            try {
              const parsed = new URL(value, location.href);
              if (parsed.protocol === 'https:'
                  && parsed.hostname.toLowerCase() === 'pbs.twimg.com'
                  && parsed.pathname.startsWith('/media/')) {
                found = parsed.href;
              }
            } catch (_) {}
            return;
          }
          if ((typeof value !== 'object' && typeof value !== 'function') || seen.has(value)) return;
          seen.add(value);
          let keys = [];
          try { keys = Object.keys(value); } catch (_) { return; }
          for (const key of keys.slice(0, 120)) {
            try { visit(value[key], depth + 1); } catch (_) {}
          }
        };
        let current = element;
        for (let i = 0; i < 5 && current; i++) {
          Object.keys(current).filter(key => key.startsWith('__react')).forEach(key => {
            try { visit(current[key], 0); } catch (_) {}
          });
          current = current.parentElement;
        }
        return found;
      };
      const appendCapturedImage = (imageURL, imageID, altText) => {
        const key = imageID || imageURL;
        if (!imageURL || !key || capturedImageKeys.has(key)) return false;
        capturedImageKeys.add(key);
        blocks.push({
          kind:'image', text:'', level:0, depth:0, styles:[], links:[],
          imageURL, imageID:imageID || null, altText:altText || null, language:null
        });
        return true;
      };
      const embeddedMediaID = element => {
        const values = [
          element.getAttribute('poster') || '',
          element.currentSrc || '',
          element.getAttribute('src') || ''
        ];
        for (const value of values) {
          const match = value.match(/\/(?:amplify_video(?:_thumb)?|ext_tw_video(?:_thumb)?|tweet_video)\/(\d{1,19})(?:\/|\.)/);
          if (match) return match[1];
        }
        return null;
      };
      const downloadableVideoURLs = (video, block) => {
        const output = new Set();
        const add = value => {
          if (typeof value !== 'string' || !value.includes('video.twimg.com')) return;
          try {
            const parsed = new URL(value, location.href);
            if (parsed.protocol !== 'https:' || parsed.hostname.toLowerCase() !== 'video.twimg.com') return;
            if (!/\.(?:mp4|m3u8)$/i.test(parsed.pathname)) return;
            output.add(parsed.href);
          } catch (_) {}
        };
        add(video.currentSrc || '');
        add(video.getAttribute('src') || '');
        [...video.querySelectorAll('source[src]')].forEach(source => add(source.getAttribute('src') || ''));

        // X plays HLS through a blob: URL, while the progressive MP4 variants
        // remain in the React media payload attached to the rendered player.
        // Read only video.twimg.com URL strings from that local component data;
        // no cookies, headers, or unrelated page state leave the web view.
        const seen = new WeakSet();
        let remaining = 25000;
        const visit = (value, depth) => {
          if (--remaining < 0 || depth > 8 || value == null) return;
          if (typeof value === 'string') { add(value); return; }
          if ((typeof value !== 'object' && typeof value !== 'function') || seen.has(value)) return;
          seen.add(value);
          let keys = [];
          try { keys = Object.keys(value); } catch (_) { return; }
          for (const key of keys.slice(0, 200)) {
            try { visit(value[key], depth + 1); } catch (_) {}
          }
        };
        let current = video;
        while (current) {
          const reactKeys = Object.keys(current).filter(key => key.startsWith('__react'));
          for (const key of reactKeys) {
            try { visit(current[key], 0); } catch (_) {}
          }
          if (current === block) break;
          current = current.parentElement;
        }

        const id = embeddedMediaID(video);
        if (id) {
          performance.getEntriesByType('resource')
            .map(entry => entry.name)
            .filter(value => value.includes(`/${id}/`))
            .forEach(add);
        }
        return [...output];
      };

      const mergeRanges = ranges => {
        const sorted = ranges
          .filter(r => r.length > 0)
          .sort((a,b) => a.offset - b.offset || a.length - b.length);
        const output = [];
        for (const current of sorted) {
          const previous = output[output.length - 1];
          const same = previous && (previous.style ? previous.style === current.style : previous.url === current.url);
          if (same && previous.offset + previous.length === current.offset) previous.length += current.length;
          else output.push({...current});
        }
        return output;
      };

      const inlineContent = block => {
        const leaves = [...block.querySelectorAll('[data-text="true"]')];
        if (!leaves.length) return {text:(block.innerText || '').trim(), styles:[], links:[]};
        let text = '';
        const styles = [];
        const links = [];
        for (const leaf of leaves) {
          const value = leaf.textContent || '';
          if (!value) continue;
          const offset = text.length;
          text += value;
          const computed = getComputedStyle(leaf);
          const weight = parseInt(computed.fontWeight || '400', 10);
          if ((Number.isFinite(weight) && weight >= 600) || computed.fontWeight === 'bold')
            styles.push({offset, length:value.length, style:'BOLD'});
          if (computed.fontStyle === 'italic')
            styles.push({offset, length:value.length, style:'ITALIC'});
          if ((computed.textDecorationLine || '').includes('underline'))
            styles.push({offset, length:value.length, style:'UNDERLINE'});
          if ((computed.textDecorationLine || '').includes('line-through'))
            styles.push({offset, length:value.length, style:'STRIKETHROUGH'});
          const anchor = leaf.closest('a[href]');
          const href = anchor ? absoluteURL(anchor.getAttribute('href')) : null;
          if (href) links.push({offset, length:value.length, url:href});
        }
        return {text, styles:mergeRanges(styles), links:mergeRanges(links)};
      };

      const tableCellContent = cell => {
        let text = '';
        const styles = [];
        const links = [];
        const walker = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          const textNode = walker.currentNode;
          const parent = textNode.parentElement;
          if (!parent || parent.closest('script, style, [aria-hidden="true"]')) continue;
          const value = textNode.nodeValue || '';
          if (!value) continue;
          const offset = text.length;
          text += value;
          const computed = getComputedStyle(parent);
          const weight = parseInt(computed.fontWeight || '400', 10);
          if ((Number.isFinite(weight) && weight >= 600) || computed.fontWeight === 'bold')
            styles.push({offset, length:value.length, style:'BOLD'});
          if (computed.fontStyle === 'italic')
            styles.push({offset, length:value.length, style:'ITALIC'});
          if ((computed.textDecorationLine || '').includes('underline'))
            styles.push({offset, length:value.length, style:'UNDERLINE'});
          if ((computed.textDecorationLine || '').includes('line-through'))
            styles.push({offset, length:value.length, style:'STRIKETHROUGH'});
          const anchor = parent.closest('a[href]');
          const href = anchor ? absoluteURL(anchor.getAttribute('href')) : null;
          if (href) links.push({offset, length:value.length, url:href});
        }
        const leading = text.length - text.trimStart().length;
        const trailingEnd = text.trimEnd().length;
        const trimRange = range => {
          const start = Math.max(range.offset, leading);
          const end = Math.min(range.offset + range.length, trailingEnd);
          return end > start ? {...range, offset:start - leading, length:end - start} : null;
        };
        return {
          text:text.trim(),
          styles:mergeRanges(styles.map(trimRange).filter(Boolean)),
          links:mergeRanges(links.map(trimRange).filter(Boolean))
        };
      };

      const blocks = [];
      const capturedImageKeys = new Set();
      const appendImage = image => {
        const captured = imageBlock(image);
        if (!captured) return false;
        const key = captured.imageID || captured.imageURL;
        if (!key || capturedImageKeys.has(key)) return false;
        capturedImageKeys.add(key);
        blocks.push(captured);
        return true;
      };
      let unsupportedBlockCount = 0;
      const cover = [...articleView.querySelectorAll('[data-testid="tweetPhoto"] img')]
        .find(img => {
          if (richRoot.contains(img)) return false;
          return articleMediaURL(img) !== null;
        });
      if (cover) {
        appendImage(cover);
      }

      const renderedBlocks = [...richRoot.querySelectorAll('[data-block="true"]')]
        .filter(node => !node.parentElement?.closest('[data-block="true"]'));

      for (const node of renderedBlocks) {
        const tag = node.tagName.toLowerCase();
        const className = String(node.className || '');
        const depthMatch = className.match(/(?:^|\s)public-DraftStyleDefault-depth(\d+)(?:\s|$)/);
        const depth = depthMatch ? Number(depthMatch[1]) : 0;

        if (tag === 'section') {
          const tombstone = node.querySelector('[data-testid="tombstone"]');
          if (tombstone) {
            const detail = (tombstone.innerText || '').trim() || '引用内容已不可用';
            blocks.push({
              kind:'unavailable_embedded_post', text:detail, level:0, depth:0,
              styles:[], links:[], imageURL:null, imageID:null, altText:null, language:null
            });
            continue;
          }
          const table = node.querySelector('table');
          if (table) {
            const tableRows = [...table.rows]
              .map(row => [...row.children]
                .filter(cell => cell.matches('th, td'))
                .map(cell => {
                  const inline = tableCellContent(cell);
                  return {
                    text:inline.text, styles:inline.styles, links:inline.links,
                    isHeader:cell.tagName.toLowerCase() === 'th',
                    columnSpan:Math.max(1, Number(cell.getAttribute('colspan') || '1')),
                    rowSpan:Math.max(1, Number(cell.getAttribute('rowspan') || '1'))
                  };
                }))
              .filter(row => row.length > 0);
            if (!tableRows.length) { unsupportedBlockCount += 1; continue; }
            blocks.push({
              kind:'table',
              text:tableRows.flat().map(cell => cell.text).join('\n'),
              level:0, depth:0, styles:[], links:[], imageURL:null, imageID:null,
              altText:null, language:null, tableRows
            });
            continue;
          }
          // A quoted X Article is a complete nested <article> with many
          // profile, analytics and media links. Preserve its exact position,
          // but archive only the canonical status/article URL. Selecting the
          // first anchor used to save the author's profile and the entire card
          // UI (date, excerpt and counters), which corrupted the Markdown.
          const quotedCard = node.querySelector('article, [data-testid="tweet"]');
          if (quotedCard) {
            const href = [...node.querySelectorAll('a[href]')]
              .map(anchor => canonicalXContentURL(anchor.getAttribute('href')))
              .find(Boolean);
            if (!href) { unsupportedBlockCount += 1; continue; }
            blocks.push({
              kind:'embedded_post', text:href, level:0, depth:0, styles:[],
              links:[{offset:0, length:href.length, url:href}],
              imageURL:null, imageID:null, altText:null, language:null
            });
            continue;
          }
          const embedded = node.querySelector('iframe, video, audio');
          if (embedded) {
            // Preserve an Article image when X exposes one separately from
            // the player. Videos continue through the verified MP4 pipeline;
            // audio and other embeds keep a visible source-linked marker.
            const posterImage = node.querySelector('[data-testid="tweetPhoto"] img, img');
            if (posterImage) {
              const capturedPoster = imageBlock(posterImage);
              if (capturedPoster) blocks.push(capturedPoster);
            }
            const mediaType = embedded.tagName.toLowerCase() === 'video'
              ? 'video'
              : (embedded.tagName.toLowerCase() === 'audio' ? 'audio' : 'embedded-media');
            const sourceURL = canonicalXContentURL(location.href);
            const detail = (node.innerText || '').trim().slice(0, 200);
            const mediaURLs = mediaType === 'video'
              ? downloadableVideoURLs(embedded, node)
              : [];
            const hasProgressiveMP4 = mediaURLs.some(value => {
              try {
                const path = new URL(value).pathname;
                return /\/(?:avc1|vp9)\/\d+x\d+\/[^/]+\.mp4$/i.test(path)
                  || /\/tweet_video\/[^/]+\.mp4$/i.test(path);
              } catch (_) { return false; }
            });
            if (mediaType === 'video' && !hasProgressiveMP4)
              return ERROR + "视频正在解析真实 MP4 地址。";
            blocks.push({
              kind:'embedded_media', text:detail, level:0, depth:0, styles:[],
              links:sourceURL ? [{offset:0, length:detail.length, url:sourceURL}] : [],
              imageURL:null, imageID:null, altText:null, language:null,
              embeddedMediaType:mediaType,
              embeddedMediaID:embeddedMediaID(embedded),
              embeddedMediaURLs:mediaURLs,
              posterURL:absoluteURL(embedded.getAttribute('poster') || ''),
              durationSeconds:Number.isFinite(embedded.duration) && embedded.duration > 0
                ? embedded.duration
                : null
            });
            continue;
          }
          const images = [...node.querySelectorAll('[data-testid="tweetPhoto"] img, img')]
            .filter(image => !belongsToQuotedCard(image) && articleMediaURL(image) !== null);
          if (images.length) {
            images.forEach(appendImage);
            if (!node.querySelector('[data-testid="ScrollSnap-SwipeableList"]')) continue;
          }
          const carousel = node.querySelector('[data-testid="ScrollSnap-SwipeableList"]');
          if (carousel) {
            const slides = [...carousel.querySelectorAll('a[href*="/media/"]')];
            let pendingCarousel = false;
            for (const slide of slides) {
              const id = currentArticleMediaID(slide);
              if (id && capturedImageKeys.has(id)) continue;
              const img = slide.querySelector('img');
              if (img && appendImage(img)) continue;
              const reactURL = pbsMediaURLFromNode(slide);
              if (reactURL && appendCapturedImage(reactURL, id, img?.getAttribute('alt'))) continue;
              slide.scrollIntoView({inline:'center', block:'nearest'});
              pendingCarousel = true;
            }
            if (pendingCarousel) return ERROR + "轮播图片还没有完整加载。";
            continue;
          }
          const code = node.querySelector('pre code, pre');
          if (code) {
            const languageClass = [...code.classList].find(x => x.startsWith('language-')) || '';
            blocks.push({
              kind:'code', text:code.textContent || '', level:0, depth:0, styles:[], links:[],
              imageURL:null, imageID:null, altText:null,
              language:languageClass.replace(/^language-/, '') || null
            });
            continue;
          }
          if (node.querySelector('[role="separator"]')) {
            blocks.push({kind:'divider', text:'', level:0, depth:0, styles:[], links:[], imageURL:null, imageID:null, altText:null, language:null});
            continue;
          }
          // X can leave deleted DraftJS atomic entities behind as completely
          // empty <section data-block="true"> nodes. They have no children,
          // text, media identity, or rendered height, so they are not visible
          // article content and must not be reported as an unknown block.
          // A real lazy placeholder normally reserves height or has children;
          // those still fail closed until their content finishes loading.
          const leftoverText = (node.innerText || '').trim();
          const leftoverMedia = node.querySelector('img, video, audio, iframe, table, pre');
          if (!node.firstElementChild && !leftoverText && node.getBoundingClientRect().height <= 0.5) {
            continue;
          }
          if (!leftoverText && !leftoverMedia) continue;

          const quotedHref = [...node.querySelectorAll('a[href]')]
            .map(anchor => canonicalXContentURL(anchor.getAttribute('href')))
            .find(href => {
              if (!href) return false;
              const id = href.match(/\/(?:status|article)\/(\d{1,19})(?:\/|$)/)?.[1];
              return id && id !== pathMatch[1];
            });
          if (quotedHref) {
            blocks.push({
              kind:'embedded_post', text:quotedHref, level:0, depth:0, styles:[],
              links:[{offset:0, length:quotedHref.length, url:quotedHref}],
              imageURL:null, imageID:null, altText:null, language:null
            });
            continue;
          }

          const externalHref = [...node.querySelectorAll('a[href]')]
            .map(anchor => absoluteURL(anchor.getAttribute('href')))
            .find(href => {
              if (!href) return false;
              try {
                const host = new URL(href).hostname.toLowerCase().replace(/^(?:www\.|mobile\.)/, '');
                return host !== 'x.com' && host !== 'twitter.com' && host !== 't.co';
              } catch (_) { return false; }
            });
          if (externalHref) {
            const label = leftoverText.split('\n').map(line => line.trim()).find(Boolean) || externalHref;
            const text = label.slice(0, 300);
            blocks.push({
              kind:'paragraph', text, level:0, depth:0, styles:[],
              links:[{offset:0, length:text.length, url:externalHref}],
              imageURL:null, imageID:null, altText:null, language:null
            });
            continue;
          }
          unsupportedBlockCount += 1;
          continue;
        }

        const inline = inlineContent(node);
        let kind = 'paragraph';
        let level = 0;
        let listMarker = null;
        if (/^h[1-6]$/.test(tag)) { kind = 'heading'; level = Number(tag.slice(1)); }
        else if (tag === 'blockquote' || className.includes('longform-blockquote')) kind = 'quote';
        else if (tag === 'li') {
          const exactClasses = node.classList;
          const explicitlyOrdered = exactClasses.contains('longform-ordered-list-item')
            || exactClasses.contains('public-DraftStyleDefault-orderedListItem');
          const isOrdered = node.parentElement?.tagName.toLowerCase() === 'ol' || explicitlyOrdered;
          kind = isOrdered ? 'ordered_list_item' : 'unordered_list_item';
          if (isOrdered) {
            const list = node.parentElement;
            const siblings = list ? [...list.children].filter(child => child.tagName.toLowerCase() === 'li') : [];
            const start = Math.max(1, Number(list?.getAttribute('start') || '1'));
            const explicitValue = Number(node.getAttribute('value') || '');
            const ordinal = Number.isFinite(explicitValue) && explicitValue > 0
              ? explicitValue
              : start + Math.max(0, siblings.indexOf(node));
            listMarker = `${ordinal}.`;
          }
        } else if ((tag === 'ul' || tag === 'ol') && node.querySelector(':scope > [data-block="true"]')) {
          continue;
        } else if (tag === 'figure') {
          const figureImages = [...node.querySelectorAll('img')]
            .filter(image => articleMediaURL(image) !== null);
          if (figureImages.length) {
            figureImages.forEach(appendImage);
            continue;
          }
        } else if (tag === 'hr') {
          blocks.push({kind:'divider', text:'', level:0, depth:0, styles:[], links:[], imageURL:null, imageID:null, altText:null, language:null});
          continue;
        } else if (!inline.text) kind = 'blank_line';
        else if (tag !== 'div' && tag !== 'p') { unsupportedBlockCount += 1; continue; }

        blocks.push({
          kind, text:inline.text, level, depth, styles:inline.styles, links:inline.links,
          imageURL:null, imageID:null, altText:null, language:null, listMarker
        });
      }

      if (!blocks.some(b => b.text.trim().length > 0))
        return ERROR + "正文块还没有完整加载。";

      const visibleArticleImages = [...articleView.querySelectorAll('[data-testid="tweetPhoto"] img')]
        .filter(image => !belongsToQuotedCard(image) && articleMediaURL(image) !== null);
      if (visibleArticleImages.some(image => !image.complete || image.naturalWidth <= 0))
        return ERROR + "文章原图还没有完整加载。";

      const expectedMediaIDs = new Set(
        [...articleView.querySelectorAll('a[href*="/media/"]')]
          .filter(anchor => !belongsToQuotedCard(anchor))
          .filter(anchor => !isVideoChromeAnchor(anchor))
          .filter(anchor => {
            const img = anchor.querySelector('img');
            if (img) return articleMediaURL(img) !== null;
            // Virtualized carousel slides keep their /media/ links even when
            // the <img> has not mounted. Those still belong to the Article.
            return Boolean(anchor.closest('[data-testid="ScrollSnap-SwipeableList"]'));
          })
          .map(currentArticleMediaID)
          .filter(Boolean)
      );
      const capturedMediaIDs = new Set(
        blocks.filter(block => block.kind === 'image').map(block => block.imageID).filter(Boolean)
      );
      const missingMediaIDs = [...expectedMediaIDs]
        .filter(mediaID => !capturedMediaIDs.has(mediaID));
      if (missingMediaIDs.length)
        return ERROR + `文章图片尚未齐全（${capturedMediaIDs.size}/${expectedMediaIDs.size}）。`;

      return JSON.stringify({
        postID:pathMatch[1], title, authorHandle, authorName,
        publishedAt:timeNode?.getAttribute('datetime') || null,
        pageURL:location.href, blocks, unsupportedBlockCount,
        disclosureChromeText: disclosure.chromeText,
        disclosureLinkURLs: disclosure.linkURLs,
        disclosureTestIDs: disclosure.testIDs
      });
    })()
    """#

    fileprivate static let disclosureScript = #"""
    (() => {
      const ERROR = "__X_CAPTURE_ERROR__:";
      const articleView = document.querySelector('[data-testid="twitterArticleReadView"]');
      if (!articleView) return ERROR + "文章页还没有加载。";
      const titleNode = articleView.querySelector('[data-testid="twitter-article-title"]');
      const title = (titleNode?.innerText || '').trim();
      if (!title) return ERROR + "文章标题还没有加载。";
      const pathMatch = location.pathname.match(/\/(?:status|article)\/(\d{1,19})(?:\/|$)/i);
      if (!pathMatch) return ERROR + "当前地址中没有可识别的 Article Post ID。";
      const richRoot = articleView.querySelector('[data-testid="longformRichTextComponent"]')
        || articleView.querySelector('[data-testid="twitterArticleRichTextView"]');
      const outerArticle = articleView.parentElement?.closest('article') || articleView;
      const hidden = [];
      const hide = node => {
        if (!node) return;
        hidden.push([node, node.style.display]);
        node.style.display = 'none';
      };
      hide(richRoot);
      hide(titleNode);
      let chromeText = '';
      let linkURLs = [];
      let testIDs = [];
      try {
        const ignored = node => (richRoot && richRoot.contains(node)) || (titleNode && titleNode.contains(node));
        const ariaLabels = [...outerArticle.querySelectorAll('[aria-label]')]
          .filter(node => !ignored(node))
          .map(node => node.getAttribute('aria-label') || '')
          .filter(Boolean);
        chromeText = [(outerArticle.innerText || ''), ...ariaLabels]
          .join('\n')
          .replace(/\u00a0/g, ' ')
          .trim()
          .slice(0, 4000);
        linkURLs = [...outerArticle.querySelectorAll('a[href]')]
          .filter(anchor => !ignored(anchor))
          .map(anchor => {
            try { return new URL(anchor.getAttribute('href') || '', location.href).href; }
            catch (_) { return null; }
          })
          .filter(Boolean)
          .slice(0, 80);
        testIDs = [...outerArticle.querySelectorAll('[data-testid]')]
          .filter(node => !ignored(node))
          .map(node => node.getAttribute('data-testid') || '')
          .filter(Boolean)
          .slice(0, 80);
      } finally {
        hidden.forEach(([node, display]) => { node.style.display = display; });
      }
      return JSON.stringify({
        postID: pathMatch[1],
        title,
        pageURL: location.href,
        blocks: [],
        unsupportedBlockCount: 0,
        disclosureChromeText: chromeText,
        disclosureLinkURLs: linkURLs,
        disclosureTestIDs: testIDs
      });
    })()
    """#
}

@MainActor
enum BrowserArticleExtractionScript {
    static let source = BrowserArticleCaptureController.extractionScript
}

@MainActor
enum BrowserArticleDisclosureScript {
    static let source = BrowserArticleCaptureController.disclosureScript
}

struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct BrowserArticleCaptureView: View {
    @EnvironmentObject private var model: AppViewModel
    @StateObject private var controller = BrowserArticleCaptureController()

    private var request: BrowserCaptureRequest? { model.currentBrowserCaptureRequest }

    var body: some View {
        VStack(spacing: 18) {
            header
            summaryCard
            downloadQueue
            footer
        }
        .padding(22)
        .frame(minWidth: 800, minHeight: model.showingCreatorArticleDiscovery ? 420 : 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            // Keep the Article DOM alive at desktop width while fully covering
            // both the main page and any X popup with the native progress UI.
            ZStack {
                BrowserWebView(webView: controller.webView)
                    .id(controller.webViewEpoch)
                    .frame(width: 1_100, height: 820)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if let popup = controller.popupWebView {
                    BrowserWebView(webView: popup)
                        .frame(width: 1_100, height: 820)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .clipped()
        .task(id: request?.id) {
            guard let request else { return }
            do {
                let payload = try await controller.captureAutomatically(request)
                try Task.checkCancellation()
                if model.isCaptureStopRequested {
                    controller.pageStatus = "采集已停止，未覆盖本地文件"
                    return
                }
                await model.scheduleCapturedArticleArchive(payload, request: request)
                model.advanceBrowserCapture()
            } catch is CancellationError {
                return
            } catch {
                if request.disclosureOnly {
                    controller.pageStatus = "未能核对商单内容，已保留本地归档，继续下一篇"
                    await model.recordDisclosureCheckSkipped(error, request: request)
                } else {
                    controller.pageStatus = "这篇文章未完成，正在继续下一篇"
                    await model.recordBrowserCaptureFailure(error, request: request)
                }
                model.advanceBrowserCapture()
            }
        }
        .interactiveDismissDisabled(controller.isAutomaticCaptureRunning)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isSyncingTrackedCreators ? "正在后台同步 X Article" : "正在后台下载 X Article")
                    .font(.title3.weight(.semibold))
                Text(model.showingCreatorArticleDiscovery
                     ? "列表读取和正文保存同时进行；已发现的文章会立刻入队下载"
                     : model.isSyncingTrackedCreators
                     ? "已同步文章自动跳过，新文章会保留文字、图片、视频和原始顺序"
                     : "自动使用 Chrome 登录态并保存文字、图片、视频和原始顺序")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Label("X API 0 次", systemImage: "checkmark.shield.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Text("\(currentDownloadNumber) / \(downloadCount)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 12) {
            if controller.isLoading || controller.isAutomaticCaptureRunning || model.isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isRunning ? model.progress.stage : controller.pageStatus)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Text(captureSummaryText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Chrome 登录态", systemImage: "key.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.green.opacity(0.1), in: Capsule())
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.12))
        }
    }

    private var downloadQueue: some View {
        List {
            ForEach(model.visibleBrowserCaptureRequests) { item in
                let state = model.browserCaptureState(for: item)
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: state.systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(color(for: state))
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.displayTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                        Text("https://x.com/\(item.link.username)/status/\(item.link.postID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Text(state.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color(for: state))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(color(for: state).opacity(0.1), in: Capsule())
                }
                .padding(.vertical, 7)
                .contextMenu {
                    if state != .saved, state != .checked, model.isPendingExactCaptureRequest(item) {
                        Button(role: .destructive) {
                            model.requestDeleteExactCaptureTask(item)
                        } label: {
                            Label("删除这个采集任务…", systemImage: "trash")
                        }
                        .help("停止当前队列并删除这个待采集任务；已有归档保留")
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(minHeight: model.showingCreatorArticleDiscovery ? 220 : 365)
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
            Text(model.showingCreatorArticleDiscovery
                 ? "列表读取和正文保存同时进行；全部结束后会统一显示结果。"
                 : model.isSyncingTrackedCreators
                 ? "浏览器页面已隐藏；同步结束后会统一显示成功、跳过和失败结果。"
                 : "浏览器页面已隐藏；全部处理结束后会统一告诉你下载结果。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.pendingExactCaptureCount > 0 {
                Button("删除待采集任务…", role: .destructive) {
                    model.requestDeleteAllExactCaptureTasks()
                }
                .help("停止当前采集并清空所有待精确采集任务；已有归档保留")
            }
            Button("隐藏到后台") { model.hideDownloadProgressWindow() }
                .help("隐藏进度窗口，当前下载和后续队列会继续在后台执行")
            Button("停止") { model.closeBrowserCapture() }
                .keyboardShortcut(.cancelAction)
                .help(model.isSyncingTrackedCreators
                      ? "立即停止本次后台同步；已完成归档保留，未完成任务之后可继续"
                      : "立即停止精确采集；未完成任务保留，之后可继续")
        }
    }

    private var downloadCount: Int {
        max(model.sessionQueuedCaptureCount, 1)
    }

    private var currentDownloadNumber: Int {
        min(model.progress.completedArticles + 1, downloadCount)
    }

    private var captureSummaryText: String {
        let backlog = model.captureBacklogCount
        let backlogNote = backlog > 0 ? " · 磁盘队列 \(backlog)" : ""
        return "保存 \(model.progress.completedArticles) · 跳过 \(model.progress.skippedArticles) · 需订阅 \(model.browserCaptureSubscriptionRequiredCount) · 失败 \(model.progress.failedArticles) · 图片 \(model.progress.uploadedImages) · 视频 \(model.progress.uploadedVideos)\(backlogNote)"
    }

    private func color(for state: BackgroundDownloadItemState) -> Color {
        switch state {
        case .queued: .secondary
        case .running, .checking: .orange
        case .saved, .checked: .green
        case .subscriptionRequired: .purple
        case .failed: .red
        }
    }
}
