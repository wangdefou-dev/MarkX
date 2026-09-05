import Foundation

public enum XArticleNavigationURL {
    public static func articleURL(authorHandle: String, postID: String) -> URL? {
        guard let handle = HandleParser.normalize(authorHandle),
              (1...19).contains(postID.count),
              postID.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://x.com/\(handle)/status/\(postID)")
    }

    /// X's current subscriber-only Article card links to the legacy-named
    /// `superfollows` route. The newer-looking creator-subscriptions route
    /// redirects to the profile and does not present the checkout screen.
    public static func subscriptionURL(authorHandle: String) -> URL? {
        guard let handle = HandleParser.normalize(authorHandle) else { return nil }
        return URL(string: "https://x.com/\(handle)/superfollows/subscribe")
    }
}
