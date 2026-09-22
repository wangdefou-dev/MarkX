import Foundation

/// Decides when a rendered Article snapshot is stable enough to archive.
/// Completeness is still enforced later by `ContentFidelityValidator`; this
/// only avoids waiting on a half-rendered page, and avoids extra idle sleeps
/// after the page is already complete.
public enum ArticleCaptureStabilityPolicy {
    public static let loadingPollNanoseconds: UInt64 = 200_000_000
    public static let confirmingPollNanoseconds: UInt64 = 400_000_000
    public static let cookieImportSettleNanoseconds: UInt64 = 400_000_000
    public static let maxPolls = 90

    public static func isStructurallyComplete(_ payload: BrowserArticleCapturePayload) -> Bool {
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
                guard urls.contains(where: isHTTPS) else { return false }
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
