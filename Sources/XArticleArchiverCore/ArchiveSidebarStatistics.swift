import Foundation

public struct ArchiveSidebarStatistics: Equatable, Sendable {
    public let allArticleCount: Int
    public let processingArticleCount: Int
    public let needsAttentionArticleCount: Int

    private let downloadedArticleCountsByCreator: [UUID: Int]

    public init(articles: [ArchivedArticle]) {
        allArticleCount = articles.count
        processingArticleCount = articles.lazy.filter(Self.isProcessing).count
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
        article.pipelineState != .committed && article.pipelineState != .failed
    }

    public static func needsAttention(_ article: ArchivedArticle) -> Bool {
        article.pipelineState == .failed || article.lastError != nil
    }
}
