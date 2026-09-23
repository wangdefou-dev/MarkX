import Foundation

public struct ArchiveSidebarStatistics: Equatable, Sendable {
    public let allArticleCount: Int
    public let commercialArticleCount: Int
    public let waitingArticleCount: Int
    public let needsAttentionArticleCount: Int

    /// Retained as a source-compatible alias for older callers. These rows are
    /// not necessarily executing; they are unfinished records waiting for the
    /// browser capture queue to resume.
    public var processingArticleCount: Int { waitingArticleCount }

    private let articleCountsByCreator: [UUID: Int]
    private let downloadedArticleCountsByCreator: [UUID: Int]

    public init(articles: [ArchivedArticle]) {
        allArticleCount = articles.count
        commercialArticleCount = articles.lazy.filter(Self.isCommercialContent).count
        waitingArticleCount = articles.lazy.filter(Self.isWaiting).count
        needsAttentionArticleCount = articles.lazy.filter(Self.needsAttention).count

        var articleCounts: [UUID: Int] = [:]
        var downloadedCounts: [UUID: Int] = [:]
        for article in articles {
            articleCounts[article.creatorID, default: 0] += 1
            if article.pipelineState == .committed {
                downloadedCounts[article.creatorID, default: 0] += 1
            }
        }
        articleCountsByCreator = articleCounts
        downloadedArticleCountsByCreator = downloadedCounts
    }

    public func articleCount(for creatorID: UUID) -> Int {
        articleCountsByCreator[creatorID, default: 0]
    }

    public func displayedArticleCount(for creator: Creator) -> Int {
        creator.knownArticleCount ?? articleCount(for: creator.id)
    }

    public func downloadedArticleCount(for creatorID: UUID) -> Int {
        downloadedArticleCountsByCreator[creatorID, default: 0]
    }

    public static func isPublishedToday(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        calendar.isDate(date, inSameDayAs: now)
    }

    public static func isCommercialContent(_ article: ArchivedArticle) -> Bool {
        article.isPaidPartnership
    }

    public static func isProcessing(_ article: ArchivedArticle) -> Bool {
        isWaiting(article)
    }

    public static func isWaiting(_ article: ArchivedArticle) -> Bool {
        article.pipelineState != .committed
            && article.pipelineState != .failed
            && article.pipelineState != .subscriptionRequired
            && article.lastError == nil
    }

    public static func needsAttention(_ article: ArchivedArticle) -> Bool {
        article.pipelineState == .failed
            || article.pipelineState == .subscriptionRequired
            || article.lastError != nil
    }

    /// Keep the current article when it still belongs to the active sidebar
    /// filter; otherwise select the first visible row. Call this in the same
    /// update as the filter change so the article list never renders with a
    /// selection that is missing from the current rows.
    public static func resolvedArticleSelection(
        current: UUID?,
        visibleIDs: [UUID]
    ) -> UUID? {
        if let current, visibleIDs.contains(current) {
            return current
        }
        return visibleIDs.first
    }
}

/// How many tracked creators are fully saved, still short of the online
/// total, or not yet counted online.
public struct CreatorArchiveCensus: Equatable, Sendable {
    public let trackedCount: Int
    public let fullyDownloadedCount: Int
    public let incompleteCount: Int
    public let unknownTotalCount: Int

    public init(creators: [Creator], downloadedCount: (UUID) -> Int) {
        trackedCount = creators.count
        var fullyDownloaded = 0
        var incomplete = 0
        var unknown = 0
        for creator in creators {
            guard let known = creator.knownArticleCount else {
                unknown += 1
                continue
            }
            if downloadedCount(creator.id) >= known {
                fullyDownloaded += 1
            } else {
                incomplete += 1
            }
        }
        fullyDownloadedCount = fullyDownloaded
        incompleteCount = incomplete
        unknownTotalCount = unknown
    }

    public var summary: String {
        var parts = ["已下完 \(fullyDownloadedCount)", "未下完 \(incompleteCount)"]
        if unknownTotalCount > 0 {
            parts.append("未核对 \(unknownTotalCount)")
        }
        return parts.joined(separator: " · ")
    }
}
