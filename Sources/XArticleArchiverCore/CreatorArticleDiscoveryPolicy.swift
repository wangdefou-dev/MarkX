import Foundation

public enum CreatorArticleDiscoveryPolicy {
    public static func shouldStopAtRequestedLimit(
        discoveredCount: Int,
        maximumArticles: Int?,
        resolvesTotalCount: Bool
    ) -> Bool {
        guard !resolvesTotalCount, let maximumArticles else { return false }
        return discoveredCount >= maximumArticles
    }

    public static func selectedCount(discoveredCount: Int, maximumArticles: Int?) -> Int {
        guard let maximumArticles else { return discoveredCount }
        return min(discoveredCount, maximumArticles)
    }

    public static func rangeDescription(maximumArticles: Int?) -> String {
        maximumArticles.map { "最近 \($0) 篇" } ?? "全部可见文章"
    }
}
