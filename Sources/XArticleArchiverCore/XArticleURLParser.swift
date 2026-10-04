import Foundation

public struct XArticleLink: Hashable, Sendable {
    public var postID: String
    public var username: String
    public var originalURL: URL

    public init(postID: String, username: String, originalURL: URL) {
        self.postID = postID
        self.username = username
        self.originalURL = originalURL
    }
}

public enum XArticleURLParser {
    private static let twitterEpochMilliseconds: UInt64 = 1_288_834_974_657

    /// Parses public X/Twitter status links and the dedicated X Article route.
    /// Both carry the owning Post's numeric ID. The username in the URL is only
    /// a loading hint; the rendered page capture resolves the actual author.
    public static func parse(_ input: String) -> [XArticleLink] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",，;；"))
        let candidates = input.components(separatedBy: separators).filter { !$0.isEmpty }
        var seenPostIDs = Set<String>()
        var output: [XArticleLink] = []

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'。！？"))
            guard let url = normalizedURL(from: trimmed),
                  let host = url.host?.lowercased(),
                  isXHost(host),
                  let match = articlePath(in: url),
                  seenPostIDs.insert(match.postID).inserted else { continue }
            output.append(XArticleLink(postID: match.postID, username: match.username, originalURL: url))
        }
        return output
    }

    /// Validates links scraped from a creator's dedicated Articles page.
    /// Owner `/status/` and `/article/` routes, plus the generic `/i/article/`
    /// route, are accepted. Analytics, quoted Posts, and other authors are not.
    public static func parseCreatorArticlesPageLinks(
        _ values: [String],
        expectedUsername: String
    ) -> [XArticleLink] {
        guard let expected = HandleParser.normalize(expectedUsername) else { return [] }
        var seenPostIDs = Set<String>()
        var output: [XArticleLink] = []

        for value in values {
            guard let link = parse(value).first else { continue }
            let parts = link.originalURL.pathComponents.filter { $0 != "/" }
            guard parts.count >= 3,
                  ["status", "article"].contains(parts[1].lowercased()),
                  !parts.contains(where: { $0.caseInsensitiveCompare("analytics") == .orderedSame }) else {
                continue
            }
            let isGenericArticleRoute = parts[0].lowercased() == "i"
                && parts[1].lowercased() == "article"
            let isOwnerRoute = link.username.caseInsensitiveCompare(expected) == .orderedSame
            guard isOwnerRoute || isGenericArticleRoute,
                  seenPostIDs.insert(link.postID).inserted else { continue }
            let owned = XArticleLink(postID: link.postID, username: expected, originalURL: link.originalURL)
            output.append(XArticleLink(
                postID: link.postID,
                username: expected,
                originalURL: XArticleNavigationURL.captureURL(for: owned)
            ))
        }
        return output
    }

    /// True when the WebView is on this creator's `/articles` list, including
    /// an optional locale prefix such as `/en/handle/articles`.
    public static func isCreatorArticlesListPath(_ pathname: String, username: String) -> Bool {
        guard let expected = HandleParser.normalize(username) else { return false }
        let trimmed = pathname.split(separator: "?").first.map(String.init) ?? pathname
        let parts = trimmed.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if parts.count == 2 {
            return HandleParser.normalize(parts[0])?.caseInsensitiveCompare(expected) == .orderedSame
                && parts[1].lowercased() == "articles"
        }
        if parts.count == 3,
           parts[0].range(of: "^[a-z]{2}(?:-[A-Za-z]{2})?$", options: .regularExpression) != nil {
            return HandleParser.normalize(parts[1])?.caseInsensitiveCompare(expected) == .orderedSame
                && parts[2].lowercased() == "articles"
        }
        return false
    }

    /// X post IDs are Snowflakes whose high bits contain the creation time.
    /// This is a source-derived fallback for the Article publish time, not the
    /// time at which the app happened to discover or archive the page.
    public static func publishedAt(forPostID postID: String) -> Date? {
        guard let snowflake = UInt64(postID), snowflake > 0 else { return nil }
        let milliseconds = (snowflake >> 22) + twitterEpochMilliseconds
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static func normalizedURL(from value: String) -> URL? {
        guard !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("https://") {
            return URL(string: value)
        }
        if value.lowercased().hasPrefix("http://") {
            return nil
        }
        if value.lowercased().hasPrefix("x.com/") || value.lowercased().hasPrefix("twitter.com/")
            || value.lowercased().hasPrefix("www.x.com/") || value.lowercased().hasPrefix("www.twitter.com/") {
            return URL(string: "https://" + value)
        }
        return nil
    }

    private static func isXHost(_ host: String) -> Bool {
        host == "x.com" || host.hasSuffix(".x.com")
            || host == "twitter.com" || host.hasSuffix(".twitter.com")
    }

    private static func articlePath(in url: URL) -> (username: String, postID: String)? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3,
              ["status", "article"].contains(parts[1].lowercased()),
              let username = HandleParser.normalize(parts[0]),
              isPostID(parts[2]) else { return nil }
        return (username, parts[2])
    }

    private static func isPostID(_ value: String) -> Bool {
        (1...19).contains(value.count) && value.allSatisfy(\.isNumber)
    }
}
