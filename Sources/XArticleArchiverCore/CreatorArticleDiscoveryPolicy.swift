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

/// Online article totals come from a full Articles-list scroll. A scan that
/// never renders cards reports 0, and that must not erase a real total or
/// hide articles that are already saved locally.
public enum CreatorArticleCountPolicy {
    public static func countToStore(scanned: Int?, existing: Int?, downloaded: Int) -> Int? {
        let positive = [scanned, existing, downloaded > 0 ? downloaded : nil]
            .compactMap { $0 }
            .filter { $0 > 0 }
        return positive.max()
    }

    /// Denominator shown beside the downloaded count. Zero is not a total
    /// when articles are already saved.
    public static func displayedTotal(known: Int?, downloaded: Int) -> Int? {
        countToStore(scanned: nil, existing: known, downloaded: downloaded)
    }
}
