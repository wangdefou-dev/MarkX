import Foundation

/// Defines which archive records still represent a precise-capture task.
///
/// The queue is derived from article records instead of living in a separate
/// table. A dismissal marker therefore has to be persisted on completed
/// archives; otherwise the same task would reappear after every app restart.
public enum ExactCaptureQueuePolicy {
    public static let dismissedWarning = "已从继续精确采集队列移除"

    public static func needsCapture(_ article: ArchivedArticle) -> Bool {
        guard !article.warnings.contains(dismissedWarning) else { return false }
        if article.pipelineState != .committed { return true }
        return article.warnings.contains { warning in
            warning.contains("未提供段落级富文本块")
                || warning.contains("精确插入位置")
                || warning.contains("富文本样式可能不完整")
                || warning.contains("等待在应用内打开 X Article")
        }
    }

    /// Returns the archived record that should remain after deleting only the
    /// task. `nil` means this is merely an unfinished placeholder and its
    /// database row can be removed safely.
    public static func articleAfterDismissingTask(_ article: ArchivedArticle) -> ArchivedArticle? {
        guard article.pipelineState == .committed || article.markdownPath != nil else {
            return nil
        }
        var preserved = article
        preserved.pipelineState = .committed
        preserved.lastError = nil
        preserved.lastSyncedAt = Date()
        if !preserved.warnings.contains(dismissedWarning) {
            preserved.warnings.append(dismissedWarning)
        }
        return preserved
    }
}
