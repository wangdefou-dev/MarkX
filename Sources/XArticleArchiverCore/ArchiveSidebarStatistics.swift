import Foundation

public struct ArchiveSidebarStatistics: Equatable, Sendable {
    public let allArticleCount: Int
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
}
