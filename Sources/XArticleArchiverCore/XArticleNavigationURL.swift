import Foundation

public enum XArticleNavigationURL {
    public static func articleURL(authorHandle: String, postID: String) -> URL? {
        guard let handle = HandleParser.normalize(authorHandle),
              (1...19).contains(postID.count),
              postID.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://x.com/\(handle)/status/\(postID)")
    }

    /// Opens the route the Articles list actually gave us. A cover card's
    /// `/i/article/<id>` is a different id from the owning status, so rewriting
    /// it to `/status/<id>` requests a post that does not exist.
    public static func captureURL(for link: XArticleLink) -> URL {
        let parts = link.originalURL.pathComponents.filter { $0 != "/" }
        if parts.count >= 3, parts[1].caseInsensitiveCompare("article") == .orderedSame {
            var components = URLComponents(url: link.originalURL, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            components?.host = "x.com"
            components?.query = nil
            components?.fragment = nil
            if let url = components?.url { return url }
            return link.originalURL
        }
        return articleURL(authorHandle: link.username, postID: link.postID) ?? link.originalURL
    }

    /// X's current subscriber-only Article card links to the legacy-named
    /// `superfollows` route. The newer-looking creator-subscriptions route
    /// redirects to the profile and does not present the checkout screen.
    public static func subscriptionURL(authorHandle: String) -> URL? {
        guard let handle = HandleParser.normalize(authorHandle) else { return nil }
        return URL(string: "https://x.com/\(handle)/superfollows/subscribe")
    }
}
