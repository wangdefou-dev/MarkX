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
    /// Only the creator's exact `/handle/status/PostID` route is accepted, so
    /// analytics links, quoted Posts, navigation links, and other authors are
    /// never added to the download queue.
    public static func parseCreatorArticlesPageLinks(
        _ values: [String],
        expectedUsername: String
    ) -> [XArticleLink] {
        guard let expected = HandleParser.normalize(expectedUsername) else { return [] }
        var seenPostIDs = Set<String>()
        var output: [XArticleLink] = []

        for value in values {
            guard let link = parse(value).first,
                  link.username.caseInsensitiveCompare(expected) == .orderedSame else { continue }
            let parts = link.originalURL.pathComponents.filter { $0 != "/" }
            guard parts.count == 3,
                  parts[1].caseInsensitiveCompare("status") == .orderedSame,
                  seenPostIDs.insert(link.postID).inserted else { continue }
            output.append(link)
        }
        return output
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
