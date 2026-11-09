import Foundation
import XArticleArchiverCore

/// Only directory bookmarks and the chosen browser ID are persisted. Cookie
/// values and decryption keys never enter preferences or the archive.
enum BrowserSessionAccess {
    static let preferredBrowserKey = "browserSession.preferredBrowser"
    static let directoryBookmarksKey = "browserSession.directoryBookmarks"

    static func probe() -> BrowserSessionProbe {
        withDirectories { roots in
            let selected = UserDefaults.standard.string(forKey: preferredBrowserKey)
            let browsers = BrowserSessionDefinition.supported.filter { selected == nil || selected == "automatic" || $0.id == selected }
            return BrowserXSessionReader.probe(browsers: browsers, customRoots: roots)
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
            return try BrowserXSessionReader.readActiveSession(customRoots: roots, preferredBrowserID: selected == "automatic" ? nil : selected)
        }
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
