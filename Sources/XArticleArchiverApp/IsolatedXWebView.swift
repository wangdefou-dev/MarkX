import WebKit

@MainActor
enum IsolatedXWebView {
    static func make(allowPopups: Bool = false) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowPopups
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        return webView
    }

    static func retire(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        webView.removeFromSuperview()
    }
}
