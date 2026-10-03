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

    /// Denominator shown beside the downloaded count. A stored zero is not a
    /// total unless this scan settled on an empty Articles list. Zero from an
    /// older failed scan stays unknown and the sidebar keeps showing "?".
    public static func displayedTotal(
        known: Int?,
        downloaded: Int,
        verifiedEmpty: Bool = false
    ) -> Int? {
        if let total = countToStore(scanned: nil, existing: known, downloaded: downloaded) {
            return total
        }
        if verifiedEmpty, downloaded == 0 {
            return 0
        }
        return nil
    }
}

/// How long an Articles list must stay unchanged at the bottom before the
/// scan treats it as finished. A page with no cards has to wait longer: a
/// short login shell or a blocked-profile gate is also "at the bottom"
/// before any Article card exists.
public enum CreatorArticleListSettlePolicy {
    public static let pollsWithCards = 5
    public static let pollsWithoutCards = 15

    public static func isSettled(
        itemCount: Int,
        unchangedAtBottom: Int,
        gateVisible: Bool
    ) -> Bool {
        if gateVisible || unchangedAtBottom <= 0 { return false }
        let required = itemCount > 0 ? pollsWithCards : pollsWithoutCards
        return unchangedAtBottom >= required
    }
}
