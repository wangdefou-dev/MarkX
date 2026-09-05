import Foundation

public enum BrowserArticleCaptureError: LocalizedError, Sendable {
    case pageNotReady(String)
    case wrongPost(expected: String, actual: String)
    case missingTitle
    case missingBody
    case missingPublishedAt
    case unsupportedRenderedBlocks(Int)
    case sourceTextMismatch
    case invalidImage(String)
    case missingVideoSource(String)
    case invalidEmbeddedArticleLink(String)

    public var errorDescription: String? {
        switch self {
        case .pageNotReady(let detail):
            "X Article 页面还没有准备好：\(detail)"
        case .wrongPost(let expected, let actual):
            "当前页面不是待保存的文章（期望 \(expected)，实际 \(actual)）"
        case .missingTitle:
            "没有读到 X Article 标题"
        case .missingBody:
            "没有读到 X Article 正文；请确认已登录并等待页面加载完成"
        case .missingPublishedAt:
            "没有读到 X Article 的发布时间，已拒绝用入库时间代替"
        case .unsupportedRenderedBlocks(let count):
            "页面中有 \(count) 个尚未支持的排版块，已拒绝生成不完整文章"
        case .sourceTextMismatch:
            "页面正文与 API 发现阶段保存的 plain_text 不一致，未覆盖本地文件"
        case .invalidImage(let value):
            "文章图片地址无效：\(value)"
        case .missingVideoSource(let value):
            "没有读到可下载的 X 视频 MP4 地址：\(value)"
        case .invalidEmbeddedArticleLink(let value):
            "引用文章卡片中没有可验证的 X 文章链接：\(value)"
        }
    }
}

/// JSON returned by the in-app WKWebView extractor. Keeping this transport
/// model in Core makes it possible to fixture-test the DOM-to-Markdown path
/// without launching a web view.
public struct BrowserArticleCapturePayload: Codable, Hashable, Sendable {
    public var postID: String
    public var title: String
    public var authorHandle: String?
    public var authorName: String?
    public var publishedAt: String?
    public var pageURL: String
    public var blocks: [BrowserCapturedBlock]
    public var unsupportedBlockCount: Int

    public init(
        postID: String,
        title: String,
        authorHandle: String? = nil,
        authorName: String? = nil,
        publishedAt: String? = nil,
        pageURL: String,
        blocks: [BrowserCapturedBlock],
        unsupportedBlockCount: Int = 0
    ) {
        self.postID = postID
        self.title = title
        self.authorHandle = authorHandle
        self.authorName = authorName
        self.publishedAt = publishedAt
        self.pageURL = pageURL
        self.blocks = blocks
        self.unsupportedBlockCount = unsupportedBlockCount
    }
}

public struct BrowserCapturedBlock: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
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
        case embeddedPost = "embedded_post"
        case embeddedMedia = "embedded_media"
    }

    public var kind: Kind
    public var text: String
    public var level: Int
    public var depth: Int
    public var styles: [InlineStyleRange]
    public var links: [BrowserCapturedLink]
    public var imageURL: String?
    public var imageID: String?
    public var altText: String?
    public var language: String?
    public var tableRows: [[BrowserCapturedTableCell]]?
    public var listMarker: String?
    public var embeddedMediaType: String?
    public var embeddedMediaID: String?
    public var embeddedMediaURLs: [String]?
    public var posterURL: String?
    public var durationSeconds: Double?

    public init(
        kind: Kind,
        text: String = "",
        level: Int = 0,
        depth: Int = 0,
        styles: [InlineStyleRange] = [],
        links: [BrowserCapturedLink] = [],
        imageURL: String? = nil,
        imageID: String? = nil,
        altText: String? = nil,
        language: String? = nil,
        tableRows: [[BrowserCapturedTableCell]]? = nil,
        listMarker: String? = nil,
        embeddedMediaType: String? = nil,
        embeddedMediaID: String? = nil,
        embeddedMediaURLs: [String]? = nil,
        posterURL: String? = nil,
        durationSeconds: Double? = nil
    ) {
        self.kind = kind
        self.text = text
        self.level = level
        self.depth = depth
        self.styles = styles
        self.links = links
        self.imageURL = imageURL
        self.imageID = imageID
        self.altText = altText
        self.language = language
        self.tableRows = tableRows
        self.listMarker = listMarker
        self.embeddedMediaType = embeddedMediaType
        self.embeddedMediaID = embeddedMediaID
        self.embeddedMediaURLs = embeddedMediaURLs
        self.posterURL = posterURL
        self.durationSeconds = durationSeconds
    }
}

public struct BrowserCapturedTableCell: Codable, Hashable, Sendable {
    public var text: String
    public var styles: [InlineStyleRange]
    public var links: [BrowserCapturedLink]
    public var isHeader: Bool
    public var columnSpan: Int
    public var rowSpan: Int

    public init(
        text: String,
        styles: [InlineStyleRange] = [],
        links: [BrowserCapturedLink] = [],
        isHeader: Bool = false,
        columnSpan: Int = 1,
        rowSpan: Int = 1
    ) {
        self.text = text
        self.styles = styles
        self.links = links
        self.isHeader = isHeader
        self.columnSpan = columnSpan
        self.rowSpan = rowSpan
    }
}

public struct BrowserCapturedLink: Codable, Hashable, Sendable {
    public var offset: Int
    public var length: Int
    public var url: String

    public init(offset: Int, length: Int, url: String) {
        self.offset = offset
        self.length = length
        self.url = url
    }
}

public struct BrowserArticleCaptureContext: Sendable {
    public var link: XArticleLink
    public var creator: Creator
    public var publishedAt: Date?
    public var sourceArticleID: String?
    public var expectedPlainText: String?

    public init(
        link: XArticleLink,
        creator: Creator,
        publishedAt: Date? = nil,
        sourceArticleID: String? = nil,
        expectedPlainText: String? = nil
    ) {
        self.link = link
        self.creator = creator
        self.publishedAt = publishedAt
        self.sourceArticleID = sourceArticleID
        self.expectedPlainText = expectedPlainText
    }
}

public enum BrowserArticleCaptureDecoder {
    public static func decode(
        _ payload: BrowserArticleCapturePayload,
        context: BrowserArticleCaptureContext
    ) throws -> CanonicalDocument {
        guard payload.postID == context.link.postID else {
            throw BrowserArticleCaptureError.wrongPost(expected: context.link.postID, actual: payload.postID)
        }
        guard payload.unsupportedBlockCount == 0 else {
            throw BrowserArticleCaptureError.unsupportedRenderedBlocks(payload.unsupportedBlockCount)
        }

        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BrowserArticleCaptureError.missingTitle }

        var media: [MediaAsset] = []
        var videos: [VideoAsset] = []
        var blocks: [CanonicalBlock] = []
        var usedMediaIDs = Set<String>()
        var usedVideoIDs = Set<String>()
        var embeddedMediaCounts: [String: Int] = [:]

        for captured in payload.blocks {
            let canonicalKind: CanonicalBlockKind
            switch captured.kind {
            case .paragraph: canonicalKind = .paragraph
            case .blankLine: canonicalKind = .blankLine
            case .heading: canonicalKind = .heading
            case .unorderedListItem: canonicalKind = .unorderedListItem
            case .orderedListItem: canonicalKind = .orderedListItem
            case .quote: canonicalKind = .quote
            case .code: canonicalKind = .code
            case .divider: canonicalKind = .divider
            case .table: canonicalKind = .table
            case .image: canonicalKind = .image
            case .embeddedPost: canonicalKind = .embeddedPost
            case .embeddedMedia: canonicalKind = .video
            }

            if captured.kind == .image {
                guard let rawURL = captured.imageURL,
                      let sourceURL = originalImageURL(from: rawURL) else {
                    throw BrowserArticleCaptureError.invalidImage(captured.imageURL ?? "缺少 URL")
                }
                let baseID = captured.imageID?.trimmingCharacters(in: .whitespacesAndNewlines)
                var mediaID = (baseID?.isEmpty == false ? baseID! : "browser-\(ContentHasher.sha256(sourceURL.absoluteString).prefix(20))")
                var suffix = 2
                while !usedMediaIDs.insert(mediaID).inserted {
                    mediaID = "\(baseID ?? "browser-image")-\(suffix)"
                    suffix += 1
                }
                media.append(MediaAsset(
                    id: mediaID,
                    sourceURL: sourceURL,
                    altText: normalizedAltText(captured.altText),
                    position: media.count
                ))
                blocks.append(CanonicalBlock(
                    kind: .image,
                    mediaID: mediaID,
                    sourceEntityType: "browser-rendered-image"
                ))
                continue
            }

            if captured.kind == .embeddedPost {
                let candidates = captured.links.map(\.url) + [captured.text]
                guard let referenceURL = candidates.lazy.compactMap(normalizedEmbeddedArticleURL(from:)).first else {
                    throw BrowserArticleCaptureError.invalidEmbeddedArticleLink(captured.text)
                }
                let linkText = referenceURL.absoluteString
                blocks.append(CanonicalBlock(
                    kind: .embeddedPost,
                    text: linkText,
                    links: [LinkRange(offset: 0, length: linkText.utf16.count, url: referenceURL)],
                    sourceEntityType: "browser-rendered-article-link"
                ))
                continue
            }

            if captured.kind == .embeddedMedia {
                let mediaType = normalizedEmbeddedMediaType(captured.embeddedMediaType)
                embeddedMediaCounts[mediaType, default: 0] += 1
                if mediaType == "video" {
                    guard let sourceURL = preferredVideoURL(from: captured.embeddedMediaURLs ?? []) else {
                        throw BrowserArticleCaptureError.missingVideoSource(
                            captured.embeddedMediaID ?? captured.text
                        )
                    }
                    let rawID = captured.embeddedMediaID?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let baseID = rawID?.isEmpty == false
                        ? rawID!
                        : "browser-video-\(ContentHasher.sha256(sourceURL.absoluteString).prefix(20))"
                    var videoID = baseID
                    var suffix = 2
                    while !usedVideoIDs.insert(videoID).inserted {
                        videoID = "\(baseID)-\(suffix)"
                        suffix += 1
                    }
                    let duration = captured.durationSeconds.flatMap {
                        $0.isFinite && $0 > 0 ? $0 : nil
                    }
                    videos.append(VideoAsset(
                        id: videoID,
                        sourceURL: sourceURL,
                        posterURL: captured.posterURL.flatMap(normalizedVideoPosterURL(from:)),
                        position: videos.count,
                        durationSeconds: duration
                    ))
                    blocks.append(CanonicalBlock(
                        kind: .video,
                        mediaID: videoID,
                        sourceEntityType: "browser-rendered-video"
                    ))
                    continue
                }

                let sourceURL = URL(string: "https://x.com/\(context.link.username)/status/\(context.link.postID)")!
                let detail = captured.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "嵌入媒体未归档"
                let detailSuffix = detail.isEmpty || detail == "嵌入内容" ? "" : "（\(detail)）"
                let messagePrefix = "\(prefix)\(detailSuffix)，请在原文查看："
                let linkText = sourceURL.absoluteString
                blocks.append(CanonicalBlock(
                    kind: .unsupported,
                    text: messagePrefix + linkText,
                    links: [LinkRange(
                        offset: messagePrefix.utf16.count,
                        length: linkText.utf16.count,
                        url: sourceURL
                    )],
                    sourceEntityType: "browser-rendered-\(mediaType)"
                ))
                continue
            }

            let links = captured.links.compactMap { link -> LinkRange? in
                guard let url = URL(string: link.url),
                      url.scheme?.lowercased() == "https" else { return nil }
                return LinkRange(offset: link.offset, length: link.length, url: url)
            }
            let sourceType: String
            if captured.kind == .code, let language = captured.language, !language.isEmpty {
                sourceType = "browser-rendered-code:\(language)"
            } else if captured.kind == .table {
                sourceType = "browser-rendered-table"
            } else if captured.kind == .orderedListItem,
                      let marker = normalizedOrderedMarker(captured.listMarker) {
                sourceType = "ordered-marker:\(marker)"
            } else {
                sourceType = "browser-rendered-block"
            }
            let tableRows = captured.tableRows?.map { row in
                row.map { cell in
                    CanonicalTableCell(
                        text: cell.text,
                        inlineStyles: cell.styles,
                        links: cell.links.compactMap { link in
                            guard let url = URL(string: link.url),
                                  url.scheme?.lowercased() == "https" else { return nil }
                            return LinkRange(offset: link.offset, length: link.length, url: url)
                        },
                        isHeader: cell.isHeader,
                        columnSpan: cell.columnSpan,
                        rowSpan: cell.rowSpan
                    )
                }
            }
            blocks.append(CanonicalBlock(
                kind: canonicalKind,
                text: captured.text,
                level: captured.level,
                depth: captured.depth,
                inlineStyles: captured.styles,
                links: links,
                sourceEntityType: sourceType,
                tableRows: tableRows
            ))
        }

        guard blocks.contains(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.kind == .image
                || $0.kind == .video
        }) else {
            throw BrowserArticleCaptureError.missingBody
        }

        if let expected = context.expectedPlainText,
           !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           comparableText(expected) != comparableBrowserText(blocks) {
            throw BrowserArticleCaptureError.sourceTextMismatch
        }

        guard let publishedAt = payload.publishedAt.flatMap(parseDate)
            ?? context.publishedAt
            ?? XArticleURLParser.publishedAt(forPostID: context.link.postID) else {
            throw BrowserArticleCaptureError.missingPublishedAt
        }
        var creator = context.creator
        if let handle = HandleParser.normalize(payload.authorHandle ?? ""),
           handle.caseInsensitiveCompare(context.link.username) == .orderedSame {
            creator.username = handle
        }
        if let name = payload.authorName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            creator.displayName = name
        }

        var warnings: [String] = []
        let otherEmbeddedMediaCount = embeddedMediaCounts
            .filter { $0.key != "video" }
            .reduce(0) { $0 + $1.value }
        if otherEmbeddedMediaCount > 0 {
            warnings.append("文章包含 \(otherEmbeddedMediaCount) 个暂不支持转存的嵌入媒体，已在原位置保留原文查看入口")
        }

        let document = CanonicalDocument(
            title: title,
            titleSource: "rendered-page",
            authorName: creator.displayName,
            authorHandle: creator.username,
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/\(context.link.username)/status/\(context.link.postID)")!,
            sourcePostID: context.link.postID,
            sourceArticleID: context.sourceArticleID,
            publishedAt: publishedAt,
            blocks: blocks,
            media: media,
            videos: videos,
            warnings: warnings,
            sourcePlainText: context.expectedPlainText,
            sourceMediaIDs: media.map(\.id),
            sourceVideoIDs: videos.map(\.id),
            layoutFidelity: .renderedPageVerified
        )
        try ContentFidelityValidator.validateCanonical(document)
        return document
    }

    static func originalImageURL(from value: String) -> URL? {
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "pbs.twimg.com",
              components.path.hasPrefix("/media/") else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "name" }
        items.append(URLQueryItem(name: "name", value: "orig"))
        components.queryItems = items
        return components.url
    }

    static func normalizedEmbeddedArticleURL(from value: String) -> URL? {
        guard let input = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              input.scheme?.lowercased() == "https",
              let rawHost = input.host?.lowercased() else { return nil }
        let host = rawHost
            .replacingOccurrences(of: "www.", with: "", options: [.anchored])
            .replacingOccurrences(of: "mobile.", with: "", options: [.anchored])
        guard host == "x.com" || host == "twitter.com" else { return nil }

        let parts = input.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3,
              parts[2].count <= 19,
              !parts[2].isEmpty,
              parts[2].allSatisfy(\.isNumber) else { return nil }

        let isHandleRoute = parts[0].range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil
            && (parts[1] == "status" || parts[1] == "article")
        let isIdentityRoute = parts[0] == "i" && (parts[1] == "status" || parts[1] == "article")
        guard isHandleRoute || isIdentityRoute else { return nil }
        return URL(string: "https://x.com/\(parts.joined(separator: "/"))")
    }

    static func preferredVideoURL(from values: [String]) -> URL? {
        values.compactMap { value -> (url: URL, score: Int)? in
            guard let components = URLComponents(string: value),
                  components.scheme?.lowercased() == "https",
                  components.host?.lowercased() == "video.twimg.com",
                  components.path.lowercased().hasSuffix(".mp4"),
                  !components.path.lowercased().contains("/aud/") else { return nil }

            let parts = components.path.split(separator: "/").map(String.init)
            let resolution = parts.compactMap { part -> (Int, Int)? in
                let dimensions = part.split(separator: "x", maxSplits: 1)
                guard dimensions.count == 2,
                      let width = Int(dimensions[0]),
                      let height = Int(dimensions[1]),
                      width > 0, height > 0 else { return nil }
                return (width, height)
            }.max { $0.0 * $0.1 < $1.0 * $1.1 }
            let area = resolution.map { $0.0 * $0.1 } ?? 0

            // Progressive variants place the resolution directly after the
            // codec segment. Fragmented HLS init files include time-range
            // components such as /avc1/0/0/ before the resolution.
            let isProgressive: Bool
            if let codecIndex = parts.lastIndex(where: { $0 == "avc1" || $0 == "vp9" }),
               parts.indices.contains(codecIndex + 1) {
                isProgressive = parts[codecIndex + 1].contains("x")
            } else {
                isProgressive = components.path.contains("/tweet_video/")
            }
            guard isProgressive else { return nil }
            return (components.url!, (isProgressive ? 1_000_000_000 : 0) + area)
        }
        .max { $0.score < $1.score }?
        .url
    }

    private static func normalizedVideoPosterURL(from value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "pbs.twimg.com" else { return nil }
        return components.url
    }

    private static func normalizedAltText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.caseInsensitiveCompare("Image") != .orderedSame,
              normalized != "图片" else { return nil }
        return normalized
    }

    private static func normalizedOrderedMarker(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: "^[0-9]{1,6}[.)、]$", options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private static func normalizedEmbeddedMediaType(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "video": "video"
        case "audio": "audio"
        default: "embedded-media"
        }
    }

    private static func comparableBrowserText(_ blocks: [CanonicalBlock]) -> String {
        comparableText(blocks.compactMap { block -> String? in
            switch block.kind {
            case .image, .video, .divider, .code, .embeddedPost, .unsupported:
                nil
            default:
                block.text
            }
        }.joined(separator: "\n"))
    }

    private static func comparableText(_ value: String) -> String {
        let withoutListMarkers = value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .newlines)
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    return String(trimmed.dropFirst(2))
                }
                guard let delimiter = trimmed.firstIndex(where: { $0 == "、" || $0 == "." }),
                      delimiter != trimmed.startIndex,
                      trimmed[..<delimiter].allSatisfy(\.isNumber) else { return trimmed }
                return String(trimmed[trimmed.index(after: delimiter)...])
            }
            .joined(separator: "\n")
        return withoutListMarkers
            .unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func parseDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter.date(from: value)
    }
}
