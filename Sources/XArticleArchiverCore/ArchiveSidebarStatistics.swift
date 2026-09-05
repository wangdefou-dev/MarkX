import Foundation

public struct ArchiveSidebarStatistics: Equatable, Sendable {
    public let allArticleCount: Int
    public let waitingArticleCount: Int
    public let needsAttentionArticleCount: Int

    /// Retained as a source-compatible alias for older callers. These rows are
    /// not necessarily executing; they are unfinished records waiting for the
    /// browser capture queue to resume.
    public var processingArticleCount: Int { waitingArticleCount }

    private let downloadedArticleCountsByCreator: [UUID: Int]

    public init(articles: [ArchivedArticle]) {
        allArticleCount = articles.count
        waitingArticleCount = articles.lazy.filter(Self.isWaiting).count
        needsAttentionArticleCount = articles.lazy.filter(Self.needsAttention).count

        var downloadedCounts: [UUID: Int] = [:]
        for article in articles where article.pipelineState == .committed {
            downloadedCounts[article.creatorID, default: 0] += 1
        }
        downloadedArticleCountsByCreator = downloadedCounts
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
            && article.lastError == nil
    }

    public static func needsAttention(_ article: ArchivedArticle) -> Bool {
        article.pipelineState == .failed || article.lastError != nil
    }
}
