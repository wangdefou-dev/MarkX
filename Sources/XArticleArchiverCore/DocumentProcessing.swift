import CryptoKit
import Foundation

public enum DocumentProcessingError: LocalizedError, Sendable {
    case missingTitle
    case missingBody
    case missingRemoteImage(String)
    case fidelityMismatch(String)
    case invalidSourceURL

    public var errorDescription: String? {
        switch self {
        case .missingTitle: "文章没有可用标题"
        case .missingBody: "文章没有可用正文"
        case .missingRemoteImage(let id): "图片尚未存储或验证：\(id)"
        case .fidelityMismatch(let detail): "Markdown 内容一致性校验失败：\(detail)"
        case .invalidSourceURL: "原文链接无效"
        }
    }
}

public enum ContentHasher {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    public static func sourceChecksum(for document: CanonicalDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return sha256(try encoder.encode(document))
    }
}

public enum SafeFileName {
    public static func sanitize(_ input: String, maximumLength: Int = 100) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
            .union(.controlCharacters)
        let scalars = input.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }
        var value = scalars.joined()
            .replacingOccurrences(of: "..", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while value.hasPrefix(".") { value.removeFirst() }
        while value.hasSuffix(".") { value.removeLast() }
        if value.isEmpty { value = "未命名文章" }
        if value.count > maximumLength {
            value = String(value.prefix(maximumLength)).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    public static func articleFileName(title: String, publishedAt: Date, postID: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let suffix = String(postID.suffix(8))
        return "\(formatter.string(from: publishedAt))-\(sanitize(title))--\(suffix).md"
    }

    public static func creatorDirectory(handle: String, displayName: String) -> String {
        let normalizedHandle = sanitize(handle.replacingOccurrences(of: "@", with: ""), maximumLength: 40)
        return "@\(normalizedHandle) - \(sanitize(displayName, maximumLength: 60))"
    }
}

public enum ContentFidelityValidator {
    /// Validates the source-derived canonical model before any network or file
    /// mutation. A document that loses/reorders source text or media never
    /// reaches the "completed" state.
    public static func validateCanonical(_ document: CanonicalDocument) throws {
        guard document.sourceURL.scheme?.lowercased() == "https",
              let host = document.sourceURL.host?.lowercased(),
              host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com") else {
            throw DocumentProcessingError.invalidSourceURL
        }

        let mediaIDs = document.media.map(\.id)
        guard Set(mediaIDs).count == mediaIDs.count else {
            throw DocumentProcessingError.fidelityMismatch("源图片 ID 存在重复")
        }
        for (index, media) in document.media.enumerated() {
            guard media.position == index else {
                throw DocumentProcessingError.fidelityMismatch("源图片顺序不连续：\(media.id)")
            }
            guard media.sourceURL.scheme?.lowercased() == "https" else {
                throw DocumentProcessingError.fidelityMismatch("源图片不是 HTTPS：\(media.id)")
            }
        }
        if let sourceMediaIDs = document.sourceMediaIDs, sourceMediaIDs != mediaIDs {
            throw DocumentProcessingError.fidelityMismatch("图片数量或原始顺序与 X 返回结果不一致")
        }

        let videos = document.videos ?? []
        let videoIDs = videos.map(\.id)
        guard Set(videoIDs).count == videoIDs.count else {
            throw DocumentProcessingError.fidelityMismatch("源视频 ID 存在重复")
        }
        for (index, video) in videos.enumerated() {
            guard video.position == index else {
                throw DocumentProcessingError.fidelityMismatch("源视频顺序不连续：\(video.id)")
            }
            guard video.sourceURL.scheme?.lowercased() == "https",
                  video.sourceURL.host?.lowercased() == "video.twimg.com",
                  video.sourceURL.pathExtension.lowercased() == "mp4" else {
                throw DocumentProcessingError.fidelityMismatch("源视频不是可验证的 X MP4：\(video.id)")
            }
        }
        if let sourceVideoIDs = document.sourceVideoIDs, sourceVideoIDs != videoIDs {
            throw DocumentProcessingError.fidelityMismatch("视频数量或原始顺序与 X 页面结果不一致")
        }

        var imageBlockIDs: [String] = []
        for block in document.blocks where block.kind == .image {
            guard let mediaID = block.mediaID, !mediaID.isEmpty else {
                throw DocumentProcessingError.fidelityMismatch("正文中存在没有图片 ID 的图片块")
            }
            imageBlockIDs.append(mediaID)
        }
        guard imageBlockIDs.count == mediaIDs.count,
              Set(imageBlockIDs) == Set(mediaIDs),
              Set(imageBlockIDs).count == imageBlockIDs.count else {
            throw DocumentProcessingError.fidelityMismatch("正文图片块与 X 返回的图片不是一一对应")
        }

        var videoBlockIDs: [String] = []
        for block in document.blocks where block.kind == .video {
            guard let videoID = block.mediaID, !videoID.isEmpty else {
                throw DocumentProcessingError.fidelityMismatch("正文中存在没有视频 ID 的视频块")
            }
            videoBlockIDs.append(videoID)
        }
        guard videoBlockIDs.count == videoIDs.count,
              Set(videoBlockIDs) == Set(videoIDs),
              Set(videoBlockIDs).count == videoBlockIDs.count else {
            throw DocumentProcessingError.fidelityMismatch("正文视频块与 X 页面返回的视频不是一一对应")
        }

        for block in document.blocks {
            try validateInlineRanges(in: block)
            if let tableRows = block.tableRows {
                guard block.kind == .table, !tableRows.isEmpty,
                      tableRows.allSatisfy({ !$0.isEmpty }) else {
                    throw DocumentProcessingError.fidelityMismatch("表格行列结构为空或挂载在错误的正文块")
                }
                let flattenedText = tableRows.flatMap { $0 }.map(\.text).joined(separator: "\n")
                guard block.text == flattenedText else {
                    throw DocumentProcessingError.fidelityMismatch("表格单元格文字或顺序发生变化")
                }
                for cell in tableRows.flatMap({ $0 }) {
                    guard cell.columnSpan > 0, cell.rowSpan > 0 else {
                        throw DocumentProcessingError.fidelityMismatch("表格存在无效的跨行或跨列设置")
                    }
                    try validateInlineRanges(
                        text: cell.text,
                        styles: cell.inlineStyles,
                        links: cell.links,
                        context: "表格单元格"
                    )
                }
            }
        }

        if document.layoutFidelity == .textAndMediaOnly, let sourcePlainText = document.sourcePlainText {
            let expected = layoutSignature(fromPlainText: sourcePlainText)
            let actual = layoutSignature(from: document.blocks)
            guard expected == actual else {
                throw DocumentProcessingError.fidelityMismatch("正文文字、换行或列表顺序与 article.plain_text 不一致")
            }
        }
    }

    private static func validateInlineRanges(in block: CanonicalBlock) throws {
        try validateInlineRanges(
            text: block.text,
            styles: block.inlineStyles,
            links: block.links,
            context: String(block.text.prefix(40))
        )
    }

    private static func validateInlineRanges(
        text: String,
        styles: [InlineStyleRange],
        links: [LinkRange],
        context: String
    ) throws {
        let textLength = (text as NSString).length
        let ranges = styles.map { ($0.offset, $0.offset + $0.length) }
            + links.map { ($0.offset, $0.offset + $0.length) }
        for (start, end) in ranges where start < 0 || end <= start || end > textLength {
            throw DocumentProcessingError.fidelityMismatch("富文本范围越界：\(context)")
        }
    }

    private static func layoutSignature(fromPlainText text: String) -> [String] {
        normalizedLines(text).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return "B" }
            return "T:" + removingListMarker(from: trimmed)
        }
    }

    private static func layoutSignature(from blocks: [CanonicalBlock]) -> [String] {
        var signature: [String] = []
        for block in blocks {
            switch block.kind {
            case .blankLine:
                signature.append("B")
            case .image, .video, .divider:
                continue
            case .code where block.sourceEntityType == "article-code":
                // This entity is an additional X field. It is validated and
                // preserved, but is not necessarily repeated in plain_text.
                continue
            default:
                let lines = normalizedLines(block.text)
                if lines.isEmpty {
                    signature.append("T:")
                } else {
                    signature.append(contentsOf: lines.map {
                        "T:" + removingListMarker(from: $0.trimmingCharacters(in: .whitespaces))
                    })
                }
            }
        }
        return signature
    }

    private static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func removingListMarker(from line: String) -> String {
        if line.hasPrefix("• ") || line.hasPrefix("- ") || line.hasPrefix("* ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        guard let delimiter = line.firstIndex(where: { $0 == "、" || $0 == "." }), delimiter != line.startIndex else {
            return line
        }
        let prefix = line[..<delimiter]
        guard prefix.allSatisfy(\.isNumber) else { return line }
        return line[line.index(after: delimiter)...].trimmingCharacters(in: .whitespaces)
    }
}

public enum ArticleListMarkerResolver {
    private struct OrderedState {
        var ordinal: Int
        var suffix: String
    }

    /// Resolves visible ordered-list markers for both current captures and old
    /// snapshots that only knew a block was ordered. Consecutive items advance
    /// naturally, nested depths keep independent counters, and a non-ordered
    /// block starts a fresh list.
    public static func orderedMarkers(for blocks: [CanonicalBlock]) -> [String?] {
        var output = Array<String?>(repeating: nil, count: blocks.count)
        var counters: [Int: OrderedState] = [:]
        var previousWasOrdered = false
        var previousDepth: Int?

        for (index, block) in blocks.enumerated() {
            guard block.kind == .orderedListItem else {
                counters.removeAll()
                previousWasOrdered = false
                previousDepth = nil
                continue
            }

            let depth = max(0, block.depth)
            if !previousWasOrdered { counters.removeAll() }
            counters = counters.filter { $0.key <= depth }

            let explicit = explicitMarker(from: block)
            let state: OrderedState
            if let explicit,
               explicit.ordinal == 1,
               previousDepth == depth,
               let current = counters[depth] {
                // DraftJS and older X captures often expose every visual item
                // as `1.`. Within one uninterrupted list, render the sequence
                // users actually see instead of repeating the fallback.
                state = OrderedState(ordinal: current.ordinal + 1, suffix: explicit.suffix)
            } else if let explicit {
                state = explicit
            } else if previousDepth == depth, let current = counters[depth] {
                state = OrderedState(ordinal: current.ordinal + 1, suffix: current.suffix)
            } else if let current = counters[depth] {
                state = OrderedState(ordinal: current.ordinal + 1, suffix: current.suffix)
            } else {
                state = OrderedState(ordinal: 1, suffix: ".")
            }

            counters[depth] = state
            output[index] = "\(state.ordinal)\(state.suffix)"
            previousWasOrdered = true
            previousDepth = depth
        }
        return output
    }

    private static func explicitMarker(from block: CanonicalBlock) -> OrderedState? {
        let prefix = "ordered-marker:"
        guard let source = block.sourceEntityType, source.hasPrefix(prefix) else { return nil }
        let marker = String(source.dropFirst(prefix.count))
        guard let match = marker.firstMatch(of: /^([0-9]{1,6})([.)、])$/),
              let ordinal = Int(match.1), ordinal > 0 else { return nil }
        return OrderedState(ordinal: ordinal, suffix: String(match.2))
    }
}

public enum MarkdownRenderer {
    public static func render(
        document: CanonicalDocument,
        archivedAt: Date = Date(),
        archiveRoot: URL? = nil,
        markdownDirectory: URL? = nil
    ) throws -> String {
        try ContentFidelityValidator.validateCanonical(document)
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw DocumentProcessingError.missingTitle }
        guard document.blocks.contains(where: {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.kind == .image
                || $0.kind == .video
        }) else {
            throw DocumentProcessingError.missingBody
        }

        let mediaByID = Dictionary(uniqueKeysWithValues: document.media.map { ($0.id, $0) })
        let videoByID = Dictionary(uniqueKeysWithValues: (document.videos ?? []).map { ($0.id, $0) })
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(yamlQuoted(title))")
        lines.append("title_source: \(yamlQuoted(document.titleSource))")
        lines.append("author_name: \(yamlQuoted(document.authorName))")
        lines.append("author_handle: \(yamlQuoted(normalizedHandle(document.authorHandle)))")
        lines.append("content_type: \(document.contentType.rawValue)")
        lines.append("source_url: \(yamlQuoted(document.sourceURL.absoluteString))")
        lines.append("source_post_id: \(yamlQuoted(document.sourcePostID))")
        if let sourceArticleID = document.sourceArticleID {
            lines.append("source_article_id: \(yamlQuoted(sourceArticleID))")
        }
        lines.append("published_at: \(yamlQuoted(iso8601(document.publishedAt)))")
        lines.append("archived_at: \(yamlQuoted(iso8601(archivedAt)))")
        lines.append("last_synced_at: \(yamlQuoted(iso8601(archivedAt)))")
        lines.append("source_status: active")
        lines.append("images_count: \(document.media.count)")
        lines.append("videos_count: \(document.videos?.count ?? 0)")
        lines.append("content_checksum: \(yamlQuoted("sha256:\(try ContentHasher.sourceChecksum(for: document))"))")
        lines.append("exporter_version: \"0.2\"")
        lines.append("---")
        lines.append("")
        lines.append("# \(escapeHeading(title))")
        lines.append("")
        lines.append(contentsOf: try renderBodyLines(
            document: document,
            mediaByID: mediaByID,
            videoByID: videoByID,
            archiveRoot: archiveRoot,
            markdownDirectory: markdownDirectory
        ))

        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func addingExportChecksum(to markdown: String) -> String {
        let digest = ContentHasher.sha256(markdown)
        let lines = markdown.components(separatedBy: "\n")
        guard let versionIndex = lines.firstIndex(where: { $0.hasPrefix("exporter_version:") }) else {
            return markdown
        }
        var output = lines
        output.insert("export_checksum: \"\(digest)\"", at: versionIndex + 1)
        return output.joined(separator: "\n")
    }

    public static func isUnmodifiedExport(_ markdown: String) -> Bool {
        guard let expected = markdown.split(separator: "\n")
            .first(where: { $0.hasPrefix("export_checksum:") })?
            .split(separator: ":", maxSplits: 1)
            .last
            .map({ String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }) else {
            return false
        }
        let unsigned = markdown.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("export_checksum:") }
            .joined(separator: "\n")
        return ContentHasher.sha256(unsigned) == expected
    }

    public static func visibleSourceText(_ document: CanonicalDocument) -> String {
        document.blocks
            .filter { $0.kind != .image && $0.kind != .video && $0.kind != .divider }
            .map(\.text)
            .joined(separator: "\n")
            .precomposedStringWithCanonicalMapping
    }

    public static func validateRenderedText(
        document: CanonicalDocument,
        markdown: String,
        archiveRoot: URL? = nil,
        markdownDirectory: URL? = nil
    ) throws {
        try ContentFidelityValidator.validateCanonical(document)
        guard markdown.contains("source_post_id: \(yamlQuoted(document.sourcePostID))") else {
            throw DocumentProcessingError.fidelityMismatch("缺少稳定来源 ID")
        }
        guard markdown.contains("images_count: \(document.media.count)") else {
            throw DocumentProcessingError.fidelityMismatch("Markdown 图片计数与源数据不一致")
        }
        guard markdown.contains("videos_count: \(document.videos?.count ?? 0)") else {
            throw DocumentProcessingError.fidelityMismatch("Markdown 视频计数与源数据不一致")
        }
        let expectedChecksum = "content_checksum: \(yamlQuoted("sha256:\(try ContentHasher.sourceChecksum(for: document))"))"
        guard markdown.contains(expectedChecksum) else {
            throw DocumentProcessingError.fidelityMismatch("源内容校验和不一致")
        }

        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyMarker = "\n---\n\n# \(escapeHeading(title))\n\n"
        guard let bodyRange = markdown.range(of: bodyMarker) else {
            throw DocumentProcessingError.fidelityMismatch("Markdown 标题或正文边界缺失")
        }
        let actualBody = String(markdown[bodyRange.upperBound...])
        let mediaByID = Dictionary(uniqueKeysWithValues: document.media.map { ($0.id, $0) })
        let videoByID = Dictionary(uniqueKeysWithValues: (document.videos ?? []).map { ($0.id, $0) })
        var expectedLines = try renderBodyLines(
            document: document,
            mediaByID: mediaByID,
            videoByID: videoByID,
            archiveRoot: archiveRoot,
            markdownDirectory: markdownDirectory
        )
        while expectedLines.last == "" { expectedLines.removeLast() }
        let expectedBody = expectedLines.joined(separator: "\n") + "\n"
        guard actualBody == expectedBody else {
            throw DocumentProcessingError.fidelityMismatch("正文块内容、顺序或排版标记发生变化")
        }

        // `actualBody == expectedBody` above already compares every generated
        // image reference in order. Re-parsing Markdown image syntax here made
        // valid output fail on edge-case alt text and URL syntax without adding
        // any fidelity signal.
    }

    public static func renderInlineText(_ text: String, styles: [InlineStyleRange], links: [LinkRange]) -> String {
        guard !text.isEmpty else { return "" }
        if inlineRangesCross(styles: styles, links: links) {
            return renderSegmentedInlineHTML(text, styles: styles, links: links)
        }
        let utf16Length = (text as NSString).length
        struct Marker {
            let start: Int
            let end: Int
            let prefix: String
            let suffix: String
            let order: Int
        }
        var markers: [Marker] = []
        for (order, style) in styles.enumerated() where style.offset >= 0 && style.length > 0 && style.offset + style.length <= utf16Length {
            let pair: (String, String)
            switch style.style {
            case .bold: pair = ("**", "**")
            case .italic: pair = ("*", "*")
            case .underline: pair = ("<u>", "</u>")
            case .strikethrough: pair = ("~~", "~~")
            case .code: pair = ("`", "`")
            }
            markers.append(Marker(start: style.offset, end: style.offset + style.length, prefix: pair.0, suffix: pair.1, order: order))
        }
        for (offset, link) in links.enumerated() where link.offset >= 0 && link.length > 0 && link.offset + link.length <= utf16Length {
            markers.append(Marker(start: link.offset, end: link.offset + link.length, prefix: "[", suffix: "](\(link.url.absoluteString))", order: styles.count + offset))
        }
        guard !markers.isEmpty else { return escapeInlineMarkdown(text) }

        var openings: [Int: [Marker]] = [:]
        var closings: [Int: [Marker]] = [:]
        for marker in markers {
            openings[marker.start, default: []].append(marker)
            closings[marker.end, default: []].append(marker)
        }
        let boundaries = Set([0, utf16Length] + markers.flatMap { [$0.start, $0.end] }).sorted()
        let nsText = text as NSString
        var output = ""
        for index in 0..<(boundaries.count - 1) {
            let position = boundaries[index]
            if let closing = closings[position] {
                for marker in closing.sorted(by: {
                    $0.start == $1.start ? $0.order > $1.order : $0.start > $1.start
                }) { output += marker.suffix }
            }
            if let opening = openings[position] {
                for marker in opening.sorted(by: {
                    $0.end == $1.end ? $0.order < $1.order : $0.end > $1.end
                }) { output += marker.prefix }
            }
            let next = boundaries[index + 1]
            output += escapeInlineMarkdown(nsText.substring(with: NSRange(location: position, length: next - position)))
        }
        if let closing = closings[utf16Length] {
            for marker in closing.sorted(by: {
                $0.start == $1.start ? $0.order > $1.order : $0.start > $1.start
            }) { output += marker.suffix }
        }
        return output
    }

    private static func renderBodyLines(
        document: CanonicalDocument,
        mediaByID: [String: MediaAsset],
        videoByID: [String: VideoAsset],
        archiveRoot: URL?,
        markdownDirectory: URL?
    ) throws -> [String] {
        var lines: [String] = []
        let orderedMarkers = ArticleListMarkerResolver.orderedMarkers(for: document.blocks)
        for (index, block) in document.blocks.enumerated() {
            let text = renderInlineText(block.text, styles: block.inlineStyles, links: block.links)
            switch block.kind {
            case .paragraph:
                if !text.isEmpty { lines.append(text); lines.append("") }
            case .blankLine:
                lines.append("")
            case .heading:
                let level = min(6, max(2, block.level + 1))
                lines.append("\(String(repeating: "#", count: level)) \(text)")
                lines.append("")
            case .unorderedListItem:
                lines.append("\(String(repeating: "    ", count: max(0, block.depth)))- \(text)")
            case .orderedListItem:
                let marker = orderedMarkers[index] ?? "1."
                lines.append("\(String(repeating: "    ", count: max(0, block.depth)))\(marker) \(text)")
            case .quote:
                lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" })
                lines.append("")
            case .code:
                let fence = codeFence(for: block.text)
                let languagePrefix = "browser-rendered-code:"
                let language = block.sourceEntityType.flatMap { source -> String? in
                    guard source.hasPrefix(languagePrefix) else { return nil }
                    let value = String(source.dropFirst(languagePrefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty,
                          value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_+-")).contains($0) }) else {
                        return nil
                    }
                    return value
                }
                lines.append(fence + (language ?? ""))
                lines.append(block.text)
                lines.append(fence)
                lines.append("")
            case .divider:
                lines.append("---")
                lines.append("")
            case .table:
                if let tableRows = block.tableRows {
                    lines.append(contentsOf: renderTableRows(tableRows))
                } else {
                    lines.append(block.text)
                }
                lines.append("")
            case .image:
                guard let mediaID = block.mediaID, let media = mediaByID[mediaID] else {
                    throw DocumentProcessingError.fidelityMismatch("图片块找不到对应资源：\(block.mediaID ?? "unknown")")
                }
                guard let remoteURL = media.remoteURL else {
                    throw DocumentProcessingError.missingRemoteImage(media.id)
                }
                let reference = try mediaReference(
                    for: remoteURL,
                    archiveRoot: archiveRoot,
                    markdownDirectory: markdownDirectory
                )
                let alt = (media.altText?.isEmpty == false ? media.altText! : "图片 \(String(format: "%02d", media.position + 1))")
                lines.append("![\(escapeAltText(alt))](\(reference))")
                lines.append("")
            case .video:
                guard let videoID = block.mediaID, let video = videoByID[videoID] else {
                    throw DocumentProcessingError.fidelityMismatch("视频块找不到对应资源：\(block.mediaID ?? "unknown")")
                }
                guard let remoteURL = video.remoteURL else {
                    throw DocumentProcessingError.fidelityMismatch("视频尚未存储或验证：\(video.id)")
                }
                let reference = try mediaReference(
                    for: remoteURL,
                    archiveRoot: archiveRoot,
                    markdownDirectory: markdownDirectory
                )
                let escapedURL = escapeHTMLAttribute(reference)
                lines.append("<video controls preload=\"metadata\" src=\"\(escapedURL)\"></video>")
                lines.append("")
                lines.append("[打开或下载视频](\(reference))")
                lines.append("")
            case .embeddedPost:
                if let referenceURL = block.links.first?.url {
                    lines.append("引用文章：<\(referenceURL.absoluteString)>")
                } else {
                    lines.append("> \(text)")
                }
                lines.append("")
            case .unsupported:
                let type = block.sourceEntityType ?? "unknown"
                lines.append("<!-- unsupported:x-article-node:\(safeComment(type)) -->")
                if !text.isEmpty { lines.append(text) }
                lines.append("")
            }
            let nextBlock = document.blocks[safe: index + 1]
            if isListItem(block), nextBlock?.kind != .blankLine, !isListItem(nextBlock) {
                // A blank line is an explicit boundary. Without it, some
                // Markdown readers attach the following paragraph to the last
                // list item instead of starting normal body text.
                lines.append("")
            }
        }
        return lines
    }

    private static func isListItem(_ block: CanonicalBlock?) -> Bool {
        block?.kind == .orderedListItem || block?.kind == .unorderedListItem
    }

    private static func renderTableRows(_ rows: [[CanonicalTableCell]]) -> [String] {
        let width = rows.first?.count ?? 0
        let canUseGitHubMarkdown = width > 0
            && rows.allSatisfy { $0.count == width }
            && rows.flatMap({ $0 }).allSatisfy { $0.columnSpan == 1 && $0.rowSpan == 1 }
            && rows[0].allSatisfy(\.isHeader)
            && rows.dropFirst().flatMap({ $0 }).allSatisfy { !$0.isHeader }

        if canUseGitHubMarkdown {
            let markdownRow: ([CanonicalTableCell]) -> String = { row in
                "| " + row.map { cell in
                    renderInlineText(cell.text, styles: cell.inlineStyles, links: cell.links)
                        .replacingOccurrences(of: "\r\n", with: "<br>")
                        .replacingOccurrences(of: "\r", with: "<br>")
                        .replacingOccurrences(of: "\n", with: "<br>")
                }.joined(separator: " | ") + " |"
            }
            return [markdownRow(rows[0]), "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"]
                + rows.dropFirst().map(markdownRow)
        }

        var lines = ["<table>"]
        let hasHeaderRow = rows.first?.allSatisfy(\.isHeader) == true
        if hasHeaderRow, let header = rows.first {
            lines.append("  <thead>")
            lines.append("    <tr>")
            for cell in header {
                var attributes = ""
                if cell.columnSpan > 1 { attributes += " colspan=\"\(cell.columnSpan)\"" }
                if cell.rowSpan > 1 { attributes += " rowspan=\"\(cell.rowSpan)\"" }
                let content = renderInlineHTML(cell.text, styles: cell.inlineStyles, links: cell.links)
                    .replacingOccurrences(of: "\r\n", with: "<br>")
                    .replacingOccurrences(of: "\r", with: "<br>")
                    .replacingOccurrences(of: "\n", with: "<br>")
                lines.append("      <th\(attributes)>\(content)</th>")
            }
            lines.append("    </tr>")
            lines.append("  </thead>")
        }
        lines.append("  <tbody>")
        for row in rows.dropFirst(hasHeaderRow ? 1 : 0) {
            let indentation = "    "
            lines.append("\(indentation)<tr>")
            for cell in row {
                let tag = cell.isHeader ? "th" : "td"
                var attributes = ""
                if cell.columnSpan > 1 { attributes += " colspan=\"\(cell.columnSpan)\"" }
                if cell.rowSpan > 1 { attributes += " rowspan=\"\(cell.rowSpan)\"" }
                let content = renderInlineHTML(cell.text, styles: cell.inlineStyles, links: cell.links)
                    .replacingOccurrences(of: "\r\n", with: "<br>")
                    .replacingOccurrences(of: "\r", with: "<br>")
                    .replacingOccurrences(of: "\n", with: "<br>")
                lines.append("      <\(tag)\(attributes)>\(content)</\(tag)>")
            }
            lines.append("\(indentation)</tr>")
        }
        lines.append("  </tbody>")
        lines.append("</table>")
        return lines
    }

    private static func renderInlineHTML(_ text: String, styles: [InlineStyleRange], links: [LinkRange]) -> String {
        guard !text.isEmpty else { return "" }
        if inlineRangesCross(styles: styles, links: links) {
            return renderSegmentedInlineHTML(text, styles: styles, links: links)
        }
        let utf16Length = (text as NSString).length
        struct Marker {
            let start: Int
            let end: Int
            let prefix: String
            let suffix: String
            let order: Int
        }
        var markers: [Marker] = []
        for (order, style) in styles.enumerated() where style.offset >= 0 && style.length > 0 && style.offset + style.length <= utf16Length {
            let pair: (String, String)
            switch style.style {
            case .bold: pair = ("<strong>", "</strong>")
            case .italic: pair = ("<em>", "</em>")
            case .underline: pair = ("<u>", "</u>")
            case .strikethrough: pair = ("<del>", "</del>")
            case .code: pair = ("<code>", "</code>")
            }
            markers.append(Marker(start: style.offset, end: style.offset + style.length, prefix: pair.0, suffix: pair.1, order: order))
        }
        for (offset, link) in links.enumerated() where link.offset >= 0 && link.length > 0 && link.offset + link.length <= utf16Length {
            markers.append(Marker(
                start: link.offset,
                end: link.offset + link.length,
                prefix: "<a href=\"\(escapeHTMLAttribute(link.url.absoluteString))\">",
                suffix: "</a>",
                order: styles.count + offset
            ))
        }
        guard !markers.isEmpty else { return escapeHTML(text) }

        var openings: [Int: [Marker]] = [:]
        var closings: [Int: [Marker]] = [:]
        for marker in markers {
            openings[marker.start, default: []].append(marker)
            closings[marker.end, default: []].append(marker)
        }
        let boundaries = Set([0, utf16Length] + markers.flatMap { [$0.start, $0.end] }).sorted()
        let nsText = text as NSString
        var output = ""
        for index in 0..<(boundaries.count - 1) {
            let position = boundaries[index]
            if let closing = closings[position] {
                for marker in closing.sorted(by: {
                    $0.start == $1.start ? $0.order > $1.order : $0.start > $1.start
                }) { output += marker.suffix }
            }
            if let opening = openings[position] {
                for marker in opening.sorted(by: {
                    $0.end == $1.end ? $0.order < $1.order : $0.end > $1.end
                }) { output += marker.prefix }
            }
            let next = boundaries[index + 1]
            output += escapeHTML(nsText.substring(with: NSRange(location: position, length: next - position)))
        }
        if let closing = closings[utf16Length] {
            for marker in closing.sorted(by: {
                $0.start == $1.start ? $0.order > $1.order : $0.start > $1.start
            }) { output += marker.suffix }
        }
        return output
    }

    private static func inlineRangesCross(styles: [InlineStyleRange], links: [LinkRange]) -> Bool {
        let ranges = styles.map { ($0.offset, $0.offset + $0.length) }
            + links.map { ($0.offset, $0.offset + $0.length) }
        for leftIndex in ranges.indices {
            for rightIndex in ranges.indices where rightIndex > leftIndex {
                let left = ranges[leftIndex]
                let right = ranges[rightIndex]
                if (left.0 < right.0 && right.0 < left.1 && left.1 < right.1)
                    || (right.0 < left.0 && left.0 < right.1 && right.1 < left.1) {
                    return true
                }
            }
        }
        return false
    }

    private static func renderSegmentedInlineHTML(
        _ text: String,
        styles: [InlineStyleRange],
        links: [LinkRange]
    ) -> String {
        struct Span {
            let start: Int
            let end: Int
            let prefix: String
            let suffix: String
            let order: Int
        }

        let utf16Length = (text as NSString).length
        var spans: [Span] = []
        for (order, style) in styles.enumerated()
        where style.offset >= 0 && style.length > 0 && style.offset + style.length <= utf16Length {
            let pair: (String, String)
            switch style.style {
            case .bold: pair = ("<strong>", "</strong>")
            case .italic: pair = ("<em>", "</em>")
            case .underline: pair = ("<u>", "</u>")
            case .strikethrough: pair = ("<del>", "</del>")
            case .code: pair = ("<code>", "</code>")
            }
            spans.append(Span(
                start: style.offset,
                end: style.offset + style.length,
                prefix: pair.0,
                suffix: pair.1,
                order: order
            ))
        }
        for (offset, link) in links.enumerated()
        where link.offset >= 0 && link.length > 0 && link.offset + link.length <= utf16Length {
            spans.append(Span(
                start: link.offset,
                end: link.offset + link.length,
                prefix: "<a href=\"\(escapeHTMLAttribute(link.url.absoluteString))\">",
                suffix: "</a>",
                order: styles.count + offset
            ))
        }

        let boundaries = Set([0, utf16Length] + spans.flatMap { [$0.start, $0.end] }).sorted()
        let nsText = text as NSString
        var output = ""
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            let active = spans
                .filter { $0.start <= start && $0.end >= end }
                .sorted {
                    let leftLength = $0.end - $0.start
                    let rightLength = $1.end - $1.start
                    return leftLength == rightLength ? $0.order < $1.order : leftLength > rightLength
                }
            for span in active { output += span.prefix }
            output += escapeHTML(nsText.substring(with: NSRange(location: start, length: end - start)))
            for span in active.reversed() { output += span.suffix }
        }
        return output
    }

    private static func mediaReference(
        for storedURL: URL,
        archiveRoot: URL?,
        markdownDirectory: URL?
    ) throws -> String {
        if storedURL.scheme?.lowercased() == "https" {
            return storedURL.absoluteString
        }

        let relativePath = storedURL.relativeString.removingPercentEncoding ?? storedURL.relativeString
        guard storedURL.scheme == nil,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains(".."),
              relativePath.hasPrefix("media/"),
              let archiveRoot,
              let markdownDirectory else {
            throw DocumentProcessingError.fidelityMismatch("本地媒体缺少可验证的相对路径")
        }

        let root = archiveRoot.standardizedFileURL
        let base = markdownDirectory.standardizedFileURL
        let target = root.appending(path: relativePath).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/"),
              base.path == root.path || base.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: target.path) else {
            throw DocumentProcessingError.fidelityMismatch("本地媒体不存在或超出归档目录")
        }
        let baseComponents = base.pathComponents
        let targetComponents = target.pathComponents
        var commonCount = 0
        while commonCount < min(baseComponents.count, targetComponents.count),
              baseComponents[commonCount] == targetComponents[commonCount] {
            commonCount += 1
        }
        let parentComponents = Array(repeating: "..", count: baseComponents.count - commonCount)
        let childComponents = Array(targetComponents.dropFirst(commonCount))
        let portablePath = (parentComponents + childComponents).joined(separator: "/")
        guard !portablePath.isEmpty,
              let encoded = portablePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw DocumentProcessingError.fidelityMismatch("无法生成本地媒体相对路径")
        }
        return encoded
    }

    private static func escapeInlineMarkdown(_ value: String) -> String {
        var output = ""
        for character in value {
            if "\\`*_{}[]<>#+-.!|".contains(character) { output.append("\\") }
            output.append(character)
        }
        return output
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHTMLAttribute(_ value: String) -> String {
        escapeHTML(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private static func normalizedHandle(_ handle: String) -> String {
        handle.hasPrefix("@") ? handle : "@\(handle)"
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func escapeHeading(_ value: String) -> String {
        escapeInlineMarkdown(value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))
    }

    private static func escapeAltText(_ value: String) -> String {
        value.replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
    }

    private static func safeComment(_ value: String) -> String {
        value.replacingOccurrences(of: "--", with: "—").replacingOccurrences(of: ">", with: "")
    }

    private static func codeFence(for code: String) -> String {
        let longest = code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Int in
                line.split(separator: "`", omittingEmptySubsequences: false).count - 1
            }
            .max() ?? 0
        return String(repeating: "`", count: max(3, longest + 1))
    }

}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public enum HandleParser {
    public static func parse(_ input: String) -> [String] {
        var seen = Set<String>()
        return input
            .components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",;，；\t ")))
            .compactMap(normalize)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    public static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), let host = url.host?.lowercased(), host == "x.com" || host == "twitter.com" || host.hasSuffix(".x.com") || host.hasSuffix(".twitter.com") {
            value = url.pathComponents.dropFirst().first ?? ""
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "@/"))
        guard value.range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

public enum SingleCreatorInputPolicy {
    /// Keeps the single-creator field physically and semantically single-line.
    /// Normal typing is preserved exactly; when Return or a multi-line paste
    /// introduces line separators, only the first non-empty line is retained.
    public static func sanitize(_ input: String) -> String {
        let lines = input.components(separatedBy: .newlines)
        guard lines.count > 1 else { return input }
        return lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
