import Foundation

/// Decides when a rendered Article snapshot is stable enough to archive.
/// Completeness is still enforced later by `ContentFidelityValidator`; this
/// only avoids waiting on a half-rendered page, and avoids extra idle sleeps
/// after the page is already complete.
public enum ArticleCaptureStabilityPolicy {
    public static let loadingPollNanoseconds: UInt64 = 200_000_000
    public static let confirmingPollNanoseconds: UInt64 = 400_000_000
    public static let cookieImportSettleNanoseconds: UInt64 = 400_000_000
    /// About a minute of inspection: long Articles with dozens of lazily
    /// loaded images regularly needed more than the previous ~36 seconds.
    public static let maxPolls = 150
    /// Polls of an inspectable page before an unresolved video is kept as a
    /// source-linked placeholder instead of blocking the whole Article.
    public static let mediaGracePolls = 30
    /// Polls of an inspectable page without any Article view before the
    /// focal post (long post / thread) is archived instead.
    public static let postFallbackPolls = 15
    /// One fresh web view retry for pages that never became readable.
    public static let maxAttempts = 2
    /// X is a single-page app: the article is in the DOM long before the
    /// navigation reports finished, and some loads never report it at all
    /// (a hanging subresource, a navigation cancelled after commit). Inspect
    /// the page anyway once it has been loading this long.
    public static let loadingInspectionGrace: TimeInterval = 2

    public static func canInspectPage(isLoading: Bool, loadingSince: Date?, now: Date = Date()) -> Bool {
        guard isLoading else { return true }
        guard let loadingSince else { return true }
        return now.timeIntervalSince(loadingSince) >= loadingInspectionGrace
    }

    public static func isStructurallyComplete(
        _ payload: BrowserArticleCapturePayload,
        allowUnresolvedVideo: Bool = false
    ) -> Bool {
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.unsupportedBlockCount == 0,
              !title.isEmpty,
              payload.blocks.contains(where: { $0.kind != .blankLine && $0.kind != .divider }) else {
            return false
        }
        for block in payload.blocks {
            switch block.kind {
            case .image:
                guard let url = block.imageURL, isHTTPS(url) else { return false }
            case .embeddedMedia:
                let urls = block.embeddedMediaURLs ?? []
                guard allowUnresolvedVideo || urls.contains(where: isHTTPS) else { return false }
            default:
                continue
            }
        }
        return true
    }

    /// Consecutive identical complete snapshots required before save.
    /// Incomplete snapshots never qualify, even if they repeat.
    public static func requiredConsecutiveMatches(
        blockCount: Int,
        structurallyComplete: Bool
    ) -> Int {
        guard structurallyComplete else { return Int.max }
        return blockCount <= 1 ? 4 : 2
    }

    /// Explains, in user terms, why an inspectable payload is not saved yet.
    public static func incompleteReason(_ payload: BrowserArticleCapturePayload) -> String {
        if payload.unsupportedBlockCount > 0 {
            return "页面中有 \(payload.unsupportedBlockCount) 个暂不支持的排版块"
        }
        if payload.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "文章标题还没有加载"
        }
        if payload.blocks.contains(where: { $0.kind == .embeddedMedia && ($0.embeddedMediaURLs ?? []).isEmpty }) {
            return "视频地址还没有解析出来"
        }
        return "正文还在变化，等待内容稳定"
    }

    public static func pollNanoseconds(isLoading: Bool) -> UInt64 {
        isLoading ? loadingPollNanoseconds : confirmingPollNanoseconds
    }

    public static func shouldSettleAfterLoad(didJustImportCookies: Bool) -> Bool {
        didJustImportCookies
    }

    private static func isHTTPS(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("https://")
    }
}
