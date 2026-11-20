import Foundation
import WebKit
import XArticleArchiverCore

/// Only directory bookmarks and the chosen browser ID are persisted. Cookie
/// values and decryption keys never enter preferences or the archive.
enum BrowserSessionAccess {
    static let preferredBrowserKey = "browserSession.preferredBrowser"
    static let directoryBookmarksKey = "browserSession.directoryBookmarks"

    static func probe() -> BrowserSessionProbe {
        withDirectories { roots in
            // Every browser is probed so settings can list all logins.
            var result = BrowserXSessionReader.probe(customRoots: roots)
            result.selection = BrowserSessionSelection(UserDefaults.standard.string(forKey: preferredBrowserKey))
            return result
        }
    }

    static func hasLocalBrowserData() async -> Bool {
        await Task.detached(priority: .utility) {
            let result = probe()
            return !result.profiles.isEmpty || !result.issues.isEmpty
        }.value
    }

    static func readActiveSession() throws -> ChromeXSession {
        try withDirectories { roots in
            let selected = UserDefaults.standard.string(forKey: preferredBrowserKey)
            let session = try BrowserXSessionReader.readActiveSession(customRoots: roots, preferredBrowserID: selected == "automatic" ? nil : selected)
            MarkXLog.info("browser", "已读取 \(session.sourceDescription) 的 X 登录（来源设置 \(selected ?? "automatic")）")
            return session
        }
    }

    /// Replaces any X cookies already in a web view with the imported ones,
    /// so switching accounts never mixes two logins.
    @MainActor
    static func install(_ session: ChromeXSession, in store: WKHTTPCookieStore) async {
        let existing = await store.allCookies()
        for cookie in existing where isXDomain(cookie.domain) {
            await store.deleteCookie(cookie)
        }
        for cookie in session.cookies {
            await store.setCookie(cookie)
        }
    }

    private static func isXDomain(_ domain: String) -> Bool {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return ["x.com", "twitter.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func withDirectories<T>(_ body: ([String: URL]) throws -> T) rethrows -> T {
        let bookmarks = UserDefaults.standard.dictionary(forKey: directoryBookmarksKey) as? [String: Data] ?? [:]
        var roots: [String: URL] = [:]
        var scoped: [URL] = []
        for (id, bookmark) in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL else { continue }
            roots[id] = url
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
        }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try body(roots)
    }
}
