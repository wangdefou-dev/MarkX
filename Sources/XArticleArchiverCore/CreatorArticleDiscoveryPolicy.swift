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
/// scan treats it as finished. A short shell, an error page, or a card
/// layout that has not rendered is also "at the bottom". That is not proof
/// the creator has zero Articles. A zero is stored only when the page itself
/// says the list is empty.
///
/// A positive list also has to stay the same height. X often paints the first
/// screen, reports the window as already at the bottom, and only then grows
/// the real timeline scroller. Five quick polls used to store that first
/// screen as the whole archive.
public enum CreatorArticleListSettlePolicy {
    public static let pollsWithCards = 16
    public static let pollsWithoutCards = 15
    /// A spinner that never leaves, while the timeline height and the card
    /// count stay still, is not another page loading.
    public static let pollsIgnoringStuckSpinner = 18
    public static let maxPolls = 320

    public static func isSettled(
        itemCount: Int,
        unchangedAtBottom: Int,
        gateVisible: Bool,
        pageReportsEmpty: Bool = false,
        scrollExtentChanged: Bool = false
    ) -> Bool {
        if gateVisible || unchangedAtBottom <= 0 || scrollExtentChanged { return false }
        if itemCount == 0 {
            guard pageReportsEmpty else { return false }
            return unchangedAtBottom >= pollsWithoutCards
        }
        return unchangedAtBottom >= pollsWithCards
    }

    public static func loadingBlocksSettle(isLoadingMore: Bool, stableWhileSpinner: Int) -> Bool {
        isLoadingMore && stableWhileSpinner < pollsIgnoringStuckSpinner
    }
}

public struct CreatorArticleScanProgressBudget: Sendable {
    private var pollsWithoutProgress = 0
    private let limit: Int
    public init(limit: Int = CreatorArticleListSettlePolicy.maxPolls) { self.limit = limit }
    public var exhausted: Bool { pollsWithoutProgress >= limit }
    public mutating func beginPoll() { pollsWithoutProgress += 1 }
    public mutating func foundNewItems() { pollsWithoutProgress = 0 }
}

extension CreatorArticleCountPolicy {
    /// 0.3.34 marked a creator verified-empty after a short page showed no
    /// cards. Those rows are not a real zero. Forget that mark once, so the
    /// sidebar shows 0/? until a later scan sees an explicit empty state.
    public static func shouldClearUntrustedVerifiedZero(
        completeness: CompletenessStatus,
        known: Int?,
        downloaded: Int
    ) -> Bool {
        completeness == .fullArchiveVerified && downloaded == 0 && (known ?? 0) == 0
    }
}
