import Foundation

public enum ArchiveMode: String, Codable, CaseIterable, Sendable {
    case recentWindow = "recent_window"
    case fullArchive = "full_archive"

    public var displayName: String {
        switch self {
        case .recentWindow: "最近范围"
        case .fullArchive: "下载全部"
        }
    }
}

/// Centralized X API cost assumptions used by the UI safety rails. X bills
/// successful reads per returned resource, so these are upper-bound estimates,
/// not a promise about the final Developer Console charge.
public enum XAPICostEstimator {
    public static let postReadUSD = 0.005
    public static let userReadUSD = 0.010
    public static let defaultCreatorScanLimit = 50
    public static let incrementalSyncScanLimit = 20
    public static let protectedRunLimitUSD = 0.50

    public static func maximumCostUSD(
        postReadLimit: Int,
        creatorCount: Int,
        userLookupCount: Int = 0
    ) -> Double {
        let posts = max(0, postReadLimit) * max(0, creatorCount)
        return Double(posts) * postReadUSD
            + Double(max(0, userLookupCount)) * userReadUSD
    }

    public static func postReadCostUSD(_ returnedPostCount: Int) -> Double {
        Double(max(0, returnedPostCount)) * postReadUSD
    }
}

public enum CompletenessStatus: String, Codable, Sendable {
    case fullArchiveVerified = "FULL_ARCHIVE_VERIFIED"
    case recentWindowComplete = "RECENT_WINDOW_COMPLETE"
    case partial = "PARTIAL"
    case unknown = "UNKNOWN"

    public var displayName: String {
        switch self {
        case .fullArchiveVerified: "完整历史"
        case .recentWindowComplete: "最近范围已完成"
        case .partial: "部分完成"
        case .unknown: "范围未知"
        }
    }
}

public enum LongformContentType: String, Codable, CaseIterable, Sendable {
    case xArticle = "x_article"
    case longPost = "long_post"
    case thread = "thread"

    public var displayName: String {
        switch self {
        case .xArticle: "X Article"
        case .longPost: "长帖"
        case .thread: "作者线程"
        }
    }
}

public enum SourceStatus: String, Codable, Sendable {
    case active
    case edited
    case deleted
    case protected
    case suspended
    case unavailable
}

public enum PipelineState: String, Codable, Sendable {
    case discovered
    case fetched
    case parsed
    case mediaCached = "media_cached"
    case mediaUploaded = "media_uploaded"
    case rendered
    case verified
    case committed
    case subscriptionRequired = "subscription_required"
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .discovered: "已发现"
        case .fetched: "已获取"
        case .parsed: "已解析"
        case .mediaCached: "媒体已缓存"
        case .mediaUploaded: "媒体已存储"
        case .rendered: "已生成"
        case .verified: "已校验"
        case .committed: "已完成"
        case .subscriptionRequired: "需要订阅"
        case .failed: "失败"
        case .cancelled: "已停止"
        }
    }
}

public struct Creator: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var xUserID: String
    public var username: String
    public var displayName: String
    public var profileImageURL: URL?
    public var isProtected: Bool
    public var isEnabled: Bool
    public var lastSyncAt: Date?
    public var lastSeenPostID: String?
    public var completeness: CompletenessStatus
    public var knownArticleCount: Int?

    public init(
        id: UUID = UUID(),
        xUserID: String,
        username: String,
        displayName: String,
        profileImageURL: URL? = nil,
        isProtected: Bool = false,
        isEnabled: Bool = true,
        lastSyncAt: Date? = nil,
        lastSeenPostID: String? = nil,
        completeness: CompletenessStatus = .unknown,
        knownArticleCount: Int? = nil
    ) {
        self.id = id
        self.xUserID = xUserID
        self.username = username
        self.displayName = displayName
        self.profileImageURL = profileImageURL
        self.isProtected = isProtected
        self.isEnabled = isEnabled
        self.lastSyncAt = lastSyncAt
        self.lastSeenPostID = lastSeenPostID
        self.completeness = completeness
        self.knownArticleCount = knownArticleCount
    }
}

/// Selects every enabled tracked creator for a batch sync. There is
/// intentionally no `prefix`, page-size, or creator-count ceiling here: the
/// 1...100 control in the UI limits Articles per creator, never creators.
public enum SyncAllCreatorPolicy {
    public static func enabledUsernames(from creators: [Creator]) -> [String] {
        var seen = Set<String>()
        return creators.compactMap { creator in
            guard creator.isEnabled else { return nil }
            let username = creator.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else { return nil }
            guard seen.insert(username.lowercased()).inserted else { return nil }
            return username
        }
    }
}

public struct InlineStyleRange: Codable, Hashable, Sendable {
    public enum Style: String, Codable, Sendable {
        case bold = "BOLD"
        case italic = "ITALIC"
        case underline = "UNDERLINE"
        case strikethrough = "STRIKETHROUGH"
        case code = "CODE"
    }

    public var offset: Int
    public var length: Int
    public var style: Style

    public init(offset: Int, length: Int, style: Style) {
        self.offset = offset
        self.length = length
        self.style = style
    }
}

public struct LinkRange: Codable, Hashable, Sendable {
    public var offset: Int
    public var length: Int
    public var url: URL

    public init(offset: Int, length: Int, url: URL) {
        self.offset = offset
        self.length = length
        self.url = url
    }
}

public struct MediaAsset: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var sourceURL: URL
    public var altText: String?
    public var position: Int
    public var remoteURL: URL?
    public var localCachePath: String?
    public var sha256: String?

    public init(
        id: String,
        sourceURL: URL,
        altText: String? = nil,
        position: Int,
        remoteURL: URL? = nil,
        localCachePath: String? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.altText = altText
        self.position = position
        self.remoteURL = remoteURL
        self.localCachePath = localCachePath
        self.sha256 = sha256
    }
}

public struct VideoAsset: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sourceURL: URL
    public var posterURL: URL?
    public var position: Int
    public var durationSeconds: Double?
    public var localCachePath: String?
    public var remoteURL: URL?
    public var sha256: String?

    public init(
        id: String,
        sourceURL: URL,
        posterURL: URL? = nil,
        position: Int,
        durationSeconds: Double? = nil,
        localCachePath: String? = nil,
        remoteURL: URL? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.posterURL = posterURL
        self.position = position
        self.durationSeconds = durationSeconds
        self.localCachePath = localCachePath
        self.remoteURL = remoteURL
        self.sha256 = sha256
    }
}

public enum CanonicalBlockKind: String, Codable, Sendable {
    case paragraph
    case blankLine = "blank_line"
    case heading
    case unorderedListItem = "unordered_list_item"
    case orderedListItem = "ordered_list_item"
    case quote
    case code
    case divider
    case table
    case image
    case video
    case embeddedPost = "embedded_post"
    case unsupported
}

public enum LayoutFidelity: String, Codable, Sendable {
    /// X returned DraftJS blocks/entities and every declared image could be
    /// anchored to the source structure.
    case exactStructure = "exact_structure"
    /// X returned the full plain text and media list, but omitted one or more
    /// rich-text or media-position fields. Text and images are lossless; their
    /// unavailable presentation metadata must not be described as exact.
    case textAndMediaOnly = "text_and_media_only"
    /// The user opened the published X Article in the app and the archiver
    /// captured every rendered DraftJS block in DOM order. This is the only
    /// mode that may claim exact image/code placement when the public API did
    /// not return `content_state`.
    case renderedPageVerified = "rendered_page_verified"

    public var displayName: String {
        switch self {
        case .exactStructure: "排版结构已校验"
        case .textAndMediaOnly: "文字图片完整 · 排版受接口限制"
        case .renderedPageVerified: "X 页面原始排版已校验"
        }
    }
}

/// One semantic cell from a rendered X Article table. Text formatting is kept
/// separately from the flattened block text so Markdown rendering can preserve
/// both the source reading order and the visual row/column structure.
public struct CanonicalTableCell: Codable, Hashable, Sendable {
    public var text: String
    public var inlineStyles: [InlineStyleRange]
    public var links: [LinkRange]
    public var isHeader: Bool
    public var columnSpan: Int
    public var rowSpan: Int

    public init(
        text: String,
        inlineStyles: [InlineStyleRange] = [],
        links: [LinkRange] = [],
        isHeader: Bool = false,
        columnSpan: Int = 1,
        rowSpan: Int = 1
    ) {
        self.text = text
        self.inlineStyles = inlineStyles
        self.links = links
        self.isHeader = isHeader
        self.columnSpan = columnSpan
        self.rowSpan = rowSpan
    }
}

public struct CanonicalBlock: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var kind: CanonicalBlockKind
    public var text: String
    public var level: Int
    public var depth: Int
    public var inlineStyles: [InlineStyleRange]
    public var links: [LinkRange]
    public var mediaID: String?
    public var sourceEntityType: String?
    public var tableRows: [[CanonicalTableCell]]?

    public init(
        id: UUID = UUID(),
        kind: CanonicalBlockKind,
        text: String = "",
        level: Int = 0,
        depth: Int = 0,
        inlineStyles: [InlineStyleRange] = [],
        links: [LinkRange] = [],
        mediaID: String? = nil,
        sourceEntityType: String? = nil,
        tableRows: [[CanonicalTableCell]]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.level = level
        self.depth = depth
        self.inlineStyles = inlineStyles
        self.links = links
        self.mediaID = mediaID
        self.sourceEntityType = sourceEntityType
        self.tableRows = tableRows
    }
}

public struct CanonicalDocument: Codable, Hashable, Sendable {
    public var title: String
    public var titleSource: String
    public var authorName: String
    public var authorHandle: String
    public var contentType: LongformContentType
    public var sourceURL: URL
    public var sourcePostID: String
    public var sourceArticleID: String?
    public var publishedAt: Date
    public var blocks: [CanonicalBlock]
    public var media: [MediaAsset]
    /// Optional keeps source snapshots written by builds before video support
    /// backward-compatible with synthesized Codable decoding.
    public var videos: [VideoAsset]?
    public var warnings: [String]
    /// The exact full-text field returned by X, when present. Kept in the
    /// source snapshot so later rendering can be checked against the source.
    public var sourcePlainText: String?
    /// Media IDs in the order declared by X. This lets the pipeline prove that
    /// no source image disappeared or silently changed order.
    public var sourceMediaIDs: [String]?
    public var sourceVideoIDs: [String]?
    /// Optional for backward-compatible decoding of snapshots written by
    /// earlier builds.
    public var layoutFidelity: LayoutFidelity?

    public init(
        title: String,
        titleSource: String = "original",
        authorName: String,
        authorHandle: String,
        contentType: LongformContentType,
        sourceURL: URL,
        sourcePostID: String,
        sourceArticleID: String? = nil,
        publishedAt: Date,
        blocks: [CanonicalBlock],
        media: [MediaAsset] = [],
        videos: [VideoAsset] = [],
        warnings: [String] = [],
        sourcePlainText: String? = nil,
        sourceMediaIDs: [String]? = nil,
        sourceVideoIDs: [String]? = nil,
        layoutFidelity: LayoutFidelity? = nil
    ) {
        self.title = title
        self.titleSource = titleSource
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.contentType = contentType
        self.sourceURL = sourceURL
        self.sourcePostID = sourcePostID
        self.sourceArticleID = sourceArticleID
        self.publishedAt = publishedAt
        self.blocks = blocks
        self.media = media
        self.videos = videos
        self.warnings = warnings
        self.sourcePlainText = sourcePlainText
        self.sourceMediaIDs = sourceMediaIDs
        self.sourceVideoIDs = sourceVideoIDs
        self.layoutFidelity = layoutFidelity
    }
}

public struct ArchivedArticle: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var stableSourceKey: String
    public var creatorID: UUID
    public var title: String
    public var authorHandle: String
    public var contentType: LongformContentType
    public var sourceURL: URL
    public var sourcePostID: String
    public var sourceArticleID: String?
    public var publishedAt: Date
    public var archivedAt: Date
    public var lastSyncedAt: Date
    public var sourceStatus: SourceStatus
    public var sourceChecksum: String
    public var markdownPath: String?
    public var imageCount: Int
    public var videoCount: Int
    public var pipelineState: PipelineState
    public var warnings: [String]
    public var lastError: String?
    public var processingLog: [String]

    public init(
        id: UUID = UUID(),
        stableSourceKey: String,
        creatorID: UUID,
        title: String,
        authorHandle: String,
        contentType: LongformContentType,
        sourceURL: URL,
        sourcePostID: String,
        sourceArticleID: String? = nil,
        publishedAt: Date,
        archivedAt: Date = Date(),
        lastSyncedAt: Date = Date(),
        sourceStatus: SourceStatus = .active,
        sourceChecksum: String,
        markdownPath: String? = nil,
        imageCount: Int = 0,
        videoCount: Int = 0,
        pipelineState: PipelineState = .discovered,
        warnings: [String] = [],
        lastError: String? = nil,
        processingLog: [String] = []
    ) {
        self.id = id
        self.stableSourceKey = stableSourceKey
        self.creatorID = creatorID
        self.title = title
        self.authorHandle = authorHandle
        self.contentType = contentType
        self.sourceURL = sourceURL
        self.sourcePostID = sourcePostID
        self.sourceArticleID = sourceArticleID
        self.publishedAt = publishedAt
        self.archivedAt = archivedAt
        self.lastSyncedAt = lastSyncedAt
        self.sourceStatus = sourceStatus
        self.sourceChecksum = sourceChecksum
        self.markdownPath = markdownPath
        self.imageCount = imageCount
        self.videoCount = videoCount
        self.pipelineState = pipelineState
        self.warnings = warnings
        self.lastError = lastError
        self.processingLog = processingLog
    }

    public mutating func appendProcessingLog(_ message: String, at date: Date = Date()) {
        let timestamp = ISO8601DateFormatter().string(from: date)
        processingLog.append("\(timestamp)  \(message)")
        if processingLog.count > 120 {
            processingLog.removeFirst(processingLog.count - 120)
        }
    }
}

public struct SyncProgress: Sendable {
    public var stage: String
    public var scannedPosts: Int
    public var discoveredArticles: Int
    public var completedArticles: Int
    public var skippedArticles: Int
    public var uploadedImages: Int
    public var uploadedVideos: Int
    public var failedArticles: Int

    public init(
        stage: String = "准备中",
        scannedPosts: Int = 0,
        discoveredArticles: Int = 0,
        completedArticles: Int = 0,
        skippedArticles: Int = 0,
        uploadedImages: Int = 0,
        uploadedVideos: Int = 0,
        failedArticles: Int = 0
    ) {
        self.stage = stage
        self.scannedPosts = scannedPosts
        self.discoveredArticles = discoveredArticles
        self.completedArticles = completedArticles
        self.skippedArticles = skippedArticles
        self.uploadedImages = uploadedImages
        self.uploadedVideos = uploadedVideos
        self.failedArticles = failedArticles
    }
}

public struct DiscoveryResult: Sendable {
    public var documents: [CanonicalDocument]
    public var scannedPosts: Int
    public var newestPostID: String?
    public var oldestPostID: String?
    public var completeness: CompletenessStatus

    public init(
        documents: [CanonicalDocument],
        scannedPosts: Int,
        newestPostID: String?,
        oldestPostID: String?,
        completeness: CompletenessStatus
    ) {
        self.documents = documents
        self.scannedPosts = scannedPosts
        self.newestPostID = newestPostID
        self.oldestPostID = oldestPostID
        self.completeness = completeness
    }
}
