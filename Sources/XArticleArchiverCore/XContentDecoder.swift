import Foundation

public struct RawPostEnvelope: Sendable {
    public var post: JSONValue
    public var includes: JSONValue?

    public init(post: JSONValue, includes: JSONValue? = nil) {
        self.post = post
        self.includes = includes
    }
}

public enum XContentDecoderError: LocalizedError, Sendable {
    case missingDeclaredMedia([String])

    public var errorDescription: String? {
        switch self {
        case .missingDeclaredMedia(let ids):
            "X API 声明了 \(ids.count) 张文章图片，但响应没有返回对应原图：\(ids.prefix(3).joined(separator: ", "))"
        }
    }
}

public enum XContentDecoder {
    public static func decode(_ envelope: RawPostEnvelope, creator: Creator) throws -> CanonicalDocument? {
        guard let post = envelope.post.objectValue,
              let postID = post["id"]?.stringValue else { return nil }

        // This archiver deliberately accepts only the official X Article
        // object. A Note Post and a self-reply thread are different products
        // and must never consume the user's requested Article count.
        guard let article = post["article"] else { return nil }

        let sourceURL = URL(string: "https://x.com/\(creator.username)/status/\(postID)")!
        let publishedAt = parseDate(post["created_at"]?.stringValue) ?? Date()
        let articleID = article.firstString(forKeys: ["id", "article_id"])
        let titleCandidate = article.firstString(forKeys: ["title"])
            ?? post["article_title"]?.firstString(forKeys: ["title", "text"])
        let sourcePlainText = normalizedPlainText(article["plain_text"]?.stringValue)

        var warnings: [String] = []
        var blocks = decodeBlocks(from: article, warnings: &warnings)
        let usedStructuredBlocks = !blocks.isEmpty
        if !usedStructuredBlocks {
            blocks = decodeArticlePlainText(sourcePlainText, warnings: &warnings)
        }
        let appendedSupplementaryContent = appendSupplementaryArticleEntities(from: article, to: &blocks, warnings: &warnings)
        guard !blocks.isEmpty else { return nil }

        let derivedTitle = deriveTitle(from: blocks)
        let title = titleCandidate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? titleCandidate!.trimmingCharacters(in: .whitespacesAndNewlines)
            : derivedTitle
        let titleSource = titleCandidate == nil ? "derived" : "original"

        let declaredMediaIDs = declaredMediaIDs(from: envelope.post, article: article)
        let media = decodeMedia(from: envelope, article: article)
        let resolvedMediaIDs = Set(media.map(\.id))
        let missingMediaIDs = declaredMediaIDs.filter { !resolvedMediaIDs.contains($0) }
        guard missingMediaIDs.isEmpty else {
            throw XContentDecoderError.missingDeclaredMedia(missingMediaIDs)
        }
        let coverMediaID = article["cover_media"]?.stringValue
        var referencedMediaIDs = Set(blocks.compactMap(\.mediaID))
        if let coverMediaID,
           media.contains(where: { $0.id == coverMediaID }),
           referencedMediaIDs.insert(coverMediaID).inserted {
            blocks.insert(CanonicalBlock(kind: .image, mediaID: coverMediaID, sourceEntityType: "article-cover"), at: 0)
        }
        var appendedUnpositionedMedia = false
        for asset in media where referencedMediaIDs.insert(asset.id).inserted {
            blocks.append(CanonicalBlock(kind: .image, mediaID: asset.id, sourceEntityType: "unpositioned-media"))
            appendedUnpositionedMedia = true
        }
        if appendedUnpositionedMedia {
            warnings.append("X API 未返回内文图片的精确插入位置，已按 Article 媒体顺序完整保留在正文末尾")
        }
        let hasUnsupportedBlocks = blocks.contains { $0.kind == .unsupported }
        let layoutFidelity: LayoutFidelity = usedStructuredBlocks
            && !appendedUnpositionedMedia
            && !appendedSupplementaryContent
            && !hasUnsupportedBlocks
            ? .exactStructure
            : .textAndMediaOnly

        return CanonicalDocument(
            title: title,
            titleSource: titleSource,
            authorName: creator.displayName,
            authorHandle: creator.username,
            contentType: .xArticle,
            sourceURL: sourceURL,
            sourcePostID: postID,
            sourceArticleID: articleID,
            publishedAt: publishedAt,
            blocks: blocks,
            media: media,
            warnings: Array(Set(warnings)).sorted(),
            sourcePlainText: sourcePlainText,
            sourceMediaIDs: media.map(\.id),
            layoutFidelity: layoutFidelity
        )
    }

    private static func normalizedPlainText(_ rawText: String?) -> String? {
        guard let rawText else { return nil }
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let trimmed = lines.joined(separator: "\n")
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeArticlePlainText(_ rawText: String?, warnings: inout [String]) -> [CanonicalBlock] {
        guard let rawText else {
            return []
        }

        warnings.append("X API 本次提供完整 plain_text 正文，但未提供段落级富文本块；文字、换行、列表和全部图片已保留，粗体、标题层级及图片锚点无法由缺失字段还原")
        return rawText.components(separatedBy: "\n").map { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return CanonicalBlock(kind: .blankLine) }
            if let orderedItem = orderedListItem(from: line) {
                return CanonicalBlock(
                    kind: .orderedListItem,
                    text: orderedItem.text,
                    sourceEntityType: "ordered-marker:\(orderedItem.marker)"
                )
            }
            if line.hasPrefix("• ") || line.hasPrefix("- ") {
                return CanonicalBlock(kind: .unorderedListItem, text: String(line.dropFirst(2)))
            }
            return CanonicalBlock(kind: .paragraph, text: line)
        }
    }

    private static func orderedListItem(from line: String) -> (marker: String, text: String)? {
        guard let delimiter = line.firstIndex(where: { $0 == "、" || $0 == "." }), delimiter != line.startIndex else {
            return nil
        }
        let prefix = line[..<delimiter]
        guard prefix.allSatisfy(\.isNumber) else { return nil }
        let text = line[line.index(after: delimiter)...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (String(prefix) + String(line[delimiter]), text)
    }

    private static func appendSupplementaryArticleEntities(
        from article: JSONValue,
        to blocks: inout [CanonicalBlock],
        warnings: inout [String]
    ) -> Bool {
        guard let codeEntities = article["entities"]?["code"]?.arrayValue else { return false }
        let visibleText = blocks.map(\.text).joined(separator: "\n")
        var appendedCode = false
        for entity in codeEntities {
            guard let code = entity["code"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !code.isEmpty,
                  !visibleText.contains(code) else { continue }
            blocks.append(CanonicalBlock(kind: .code, text: code, sourceEntityType: "article-code"))
            appendedCode = true
        }
        if appendedCode {
            warnings.append("X API 未返回代码块的精确段落位置，已将代码内容完整保留在正文末尾")
        }
        return appendedCode
    }

    public static func decodeThreads(
        posts: [JSONValue],
        includes: JSONValue?,
        creator: Creator,
        excludingSourcePostIDs: Set<String> = []
    ) -> [CanonicalDocument] {
        let candidates = posts.compactMap { value -> ThreadPost? in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  !excludingSourcePostIDs.contains(id),
                  object["article"] == nil,
                  object["note_tweet"] == nil,
                  object["note_post"] == nil,
                  let conversationID = object["conversation_id"]?.stringValue,
                  let text = object["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            if let authorID = object["author_id"]?.stringValue, authorID != creator.xUserID { return nil }
            let repliedTo = object["referenced_tweets"]?.arrayValue?.compactMap { reference -> String? in
                guard reference["type"]?.stringValue == "replied_to" else { return nil }
                return reference["id"]?.stringValue
            } ?? []
            return ThreadPost(
                id: id,
                conversationID: conversationID,
                text: text,
                createdAt: parseDate(object["created_at"]?.stringValue) ?? .distantPast,
                repliedTo: repliedTo,
                raw: value
            )
        }

        return Dictionary(grouping: candidates, by: \.conversationID)
            .values
            .compactMap { group in
                guard group.count >= 2 else { return nil }
                let ids = Set(group.map(\.id))
                let ownsRoot = group.contains { $0.id == $0.conversationID }
                let hasInternalReply = group.contains { !$0.repliedTo.filter(ids.contains).isEmpty }
                let totalLength = group.reduce(0) { $0 + $1.text.count }
                guard (ownsRoot || hasInternalReply), totalLength >= 500 else { return nil }

                let ordered = group.sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return compareSnowflakes($0.id, $1.id)
                }
                guard let first = ordered.first else { return nil }
                var blocks: [CanonicalBlock] = []
                var media: [MediaAsset] = []
                var seenMedia = Set<String>()
                for (index, post) in ordered.enumerated() {
                    if index > 0 { blocks.append(CanonicalBlock(kind: .divider)) }
                    let paragraphs = post.text.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    blocks.append(contentsOf: paragraphs.map { CanonicalBlock(kind: .paragraph, text: $0) })
                    for asset in decodeMedia(from: RawPostEnvelope(post: post.raw, includes: includes), article: nil)
                    where seenMedia.insert(asset.id).inserted {
                        var positioned = asset
                        positioned.position = media.count
                        media.append(positioned)
                        blocks.append(CanonicalBlock(kind: .image, mediaID: asset.id, sourceEntityType: "thread-media"))
                    }
                }

                let sourceID = ordered.first(where: { $0.id == $0.conversationID })?.id ?? first.id
                return CanonicalDocument(
                    title: deriveTitle(from: blocks),
                    titleSource: "derived",
                    authorName: creator.displayName,
                    authorHandle: creator.username,
                    contentType: .thread,
                    sourceURL: URL(string: "https://x.com/\(creator.username)/status/\(sourceID)")!,
                    sourcePostID: sourceID,
                    publishedAt: first.createdAt == .distantPast ? Date() : first.createdAt,
                    blocks: blocks,
                    media: media,
                    warnings: ["由 \(ordered.count) 条同作者 Post 按时间顺序合并；仅代表本次 API 扫描到的线程内容"]
                )
            }
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    private static func decodeBlocks(from source: JSONValue, warnings: inout [String]) -> [CanonicalBlock] {
        guard let rawBlocks = findBlocks(in: source) else { return [] }
        let entities = findEntities(in: source)
        var output: [CanonicalBlock] = []

        for raw in rawBlocks {
            guard let object = raw.objectValue else { continue }
            let type = object["type"]?.stringValue ?? "unstyled"
            let text = object["text"]?.stringValue ?? ""
            let depth = object["depth"]?.intValue ?? 0
            let styles = decodeStyles(object["inlineStyleRanges"] ?? object["inline_style_ranges"])
            let entityRanges = decodeEntityRanges(object["entityRanges"] ?? object["entity_ranges"])
            let links = decodeLinks(entityRanges: entityRanges, entities: entities)

            switch type.lowercased() {
            case "header-one", "header-1", "h1":
                output.append(CanonicalBlock(kind: .heading, text: text, level: 1, depth: depth, inlineStyles: styles, links: links))
            case "header-two", "header-2", "h2":
                output.append(CanonicalBlock(kind: .heading, text: text, level: 2, depth: depth, inlineStyles: styles, links: links))
            case "header-three", "header-3", "h3":
                output.append(CanonicalBlock(kind: .heading, text: text, level: 3, depth: depth, inlineStyles: styles, links: links))
            case "header-four", "header-4", "h4":
                output.append(CanonicalBlock(kind: .heading, text: text, level: 4, depth: depth, inlineStyles: styles, links: links))
            case "header-five", "header-5", "h5":
                output.append(CanonicalBlock(kind: .heading, text: text, level: 5, depth: depth, inlineStyles: styles, links: links))
            case "header-six", "header-6", "h6":
                output.append(CanonicalBlock(kind: .heading, text: text, level: 6, depth: depth, inlineStyles: styles, links: links))
            case "unordered-list-item", "unordered_list_item":
                output.append(CanonicalBlock(kind: .unorderedListItem, text: text, depth: depth, inlineStyles: styles, links: links))
            case "ordered-list-item", "ordered_list_item":
                output.append(CanonicalBlock(kind: .orderedListItem, text: text, depth: depth, inlineStyles: styles, links: links))
            case "blockquote", "quote":
                output.append(CanonicalBlock(kind: .quote, text: text, inlineStyles: styles, links: links))
            case "code-block", "code_block", "code":
                output.append(CanonicalBlock(kind: .code, text: text))
            case "divider", "horizontal-rule":
                output.append(CanonicalBlock(kind: .divider))
            case "markdown", "table":
                output.append(CanonicalBlock(kind: .table, text: text))
            case "atomic":
                if let entity = entityForFirstRange(entityRanges, entities: entities),
                   let atomic = decodeAtomicEntity(entity) {
                    output.append(atomic)
                } else {
                    output.append(CanonicalBlock(kind: .unsupported, text: text, sourceEntityType: "atomic"))
                    warnings.append("存在无法识别的原子内容节点")
                }
            case "unstyled", "paragraph":
                output.append(CanonicalBlock(
                    kind: text.isEmpty ? .blankLine : .paragraph,
                    text: text,
                    depth: depth,
                    inlineStyles: styles,
                    links: links
                ))
            default:
                output.append(CanonicalBlock(kind: .unsupported, text: text, depth: depth, inlineStyles: styles, links: links, sourceEntityType: type))
                warnings.append("存在暂不支持的正文节点：\(type)")
            }
        }
        return output
    }

    private static func findBlocks(in value: JSONValue) -> [JSONValue]? {
        if let object = value.objectValue {
            for key in ["blocks", "content_blocks"] {
                if let blocks = object[key]?.arrayValue { return blocks }
            }
            for key in ["content_state", "content", "body", "rich_text"] {
                if let child = object[key], let blocks = findBlocks(in: child) { return blocks }
            }
            for key in object.keys.sorted() {
                if let blocks = findBlocks(in: object[key]!) { return blocks }
            }
        } else if let array = value.arrayValue {
            for child in array where child.objectValue != nil {
                if let blocks = findBlocks(in: child) { return blocks }
            }
        }
        return nil
    }

    private static func findEntities(in value: JSONValue) -> [String: JSONValue] {
        if let object = value.objectValue {
            for key in ["entityMap", "entity_map", "entities"] {
                if let map = object[key]?.objectValue { return map }
                if let array = object[key]?.arrayValue {
                    return Dictionary(uniqueKeysWithValues: array.enumerated().map { (String($0.offset), $0.element) })
                }
            }
            for key in ["content_state", "content", "body", "rich_text"] {
                if let child = object[key] {
                    let found = findEntities(in: child)
                    if !found.isEmpty { return found }
                }
            }
        }
        return [:]
    }

    private struct EntityRange {
        var offset: Int
        var length: Int
        var key: String
    }

    private static func decodeEntityRanges(_ value: JSONValue?) -> [EntityRange] {
        value?.arrayValue?.compactMap { item in
            guard let object = item.objectValue,
                  let offset = object["offset"]?.intValue,
                  let length = object["length"]?.intValue else { return nil }
            let key = object["key"]?.stringValue ?? object["entity_key"]?.stringValue ?? ""
            return EntityRange(offset: offset, length: length, key: key)
        } ?? []
    }

    private static func decodeStyles(_ value: JSONValue?) -> [InlineStyleRange] {
        value?.arrayValue?.compactMap { item in
            guard let object = item.objectValue,
                  let offset = object["offset"]?.intValue,
                  let length = object["length"]?.intValue,
                  let rawStyle = object["style"]?.stringValue?.uppercased(),
                  let style = InlineStyleRange.Style(rawValue: rawStyle) else { return nil }
            return InlineStyleRange(offset: offset, length: length, style: style)
        } ?? []
    }

    private static func decodeLinks(entityRanges: [EntityRange], entities: [String: JSONValue]) -> [LinkRange] {
        entityRanges.compactMap { range in
            guard let entity = entities[range.key],
                  let type = entity.firstString(forKeys: ["type"])?.lowercased(),
                  type == "link",
                  let rawURL = entity.firstString(forKeys: ["url", "expanded_url"]),
                  let url = URL(string: rawURL) else { return nil }
            return LinkRange(offset: range.offset, length: range.length, url: url)
        }
    }

    private static func entityForFirstRange(_ ranges: [EntityRange], entities: [String: JSONValue]) -> JSONValue? {
        guard let key = ranges.first?.key else { return nil }
        return entities[key]
    }

    private static func decodeAtomicEntity(_ entity: JSONValue) -> CanonicalBlock? {
        let type = entity.firstString(forKeys: ["type"])?.lowercased() ?? "unknown"
        switch type {
        case "image", "photo":
            let mediaID = entity.firstString(forKeys: ["media_id", "media_key", "id", "entity_key"])
            return CanonicalBlock(kind: .image, mediaID: mediaID, sourceEntityType: type)
        case "post", "tweet", "embedded_post":
            let text = entity.firstString(forKeys: ["text", "post_id", "tweet_id"]) ?? "在 X 查看嵌入内容"
            return CanonicalBlock(kind: .embeddedPost, text: text, sourceEntityType: type)
        case "divider":
            return CanonicalBlock(kind: .divider)
        case "markdown":
            let markdown = entity.firstString(forKeys: ["markdown", "text"]) ?? ""
            return CanonicalBlock(kind: .table, text: markdown, sourceEntityType: type)
        default:
            return CanonicalBlock(kind: .unsupported, sourceEntityType: type)
        }
    }

    private static func decodeMedia(from envelope: RawPostEnvelope, article: JSONValue?) -> [MediaAsset] {
        var candidates: [(String?, URL, String?)] = []
        var orderedIncludeIDs: [String] = []
        var allowedIncludeIDs = Set<String>()
        func appendAllowedID(_ id: String?) {
            guard let id, !id.isEmpty, allowedIncludeIDs.insert(id).inserted else { return }
            orderedIncludeIDs.append(id)
        }
        for id in declaredMediaIDs(from: envelope.post, article: article) { appendAllowedID(id) }
        if let article {
            collectMedia(in: article, allowedIDs: nil, candidates: &candidates)
        }
        if let includes = envelope.includes {
            collectMedia(in: includes, allowedIDs: allowedIncludeIDs, candidates: &candidates)
        }

        var candidateByID: [String: (URL, String?)] = [:]
        for candidate in candidates {
            guard let id = candidate.0, candidateByID[id] == nil else { continue }
            candidateByID[id] = (candidate.1, candidate.2)
        }

        var seen = Set<String>()
        var assets: [MediaAsset] = []
        for id in orderedIncludeIDs {
            guard let candidate = candidateByID[id], seen.insert(id).inserted else { continue }
            assets.append(MediaAsset(id: id, sourceURL: candidate.0, altText: candidate.1, position: assets.count))
        }
        for candidate in candidates {
            let key = candidate.0 ?? candidate.1.absoluteString
            guard seen.insert(key).inserted else { continue }
            assets.append(MediaAsset(id: key, sourceURL: candidate.1, altText: candidate.2, position: assets.count))
        }
        return assets
    }

    private static func declaredMediaIDs(from post: JSONValue, article: JSONValue?) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        func append(_ id: String?) {
            guard let id, !id.isEmpty, seen.insert(id).inserted else { return }
            output.append(id)
        }
        if let article {
            append(article["cover_media"]?.stringValue)
            if let mediaEntities = article["media_entities"]?.arrayValue {
                for entity in mediaEntities {
                    append(entity.stringValue ?? entity.firstString(forKeys: ["media_key", "media_id", "id"]))
                }
            }
            for id in article.collectStrings(forKeys: ["media_key", "media_id"]) { append(id) }
        }
        if let keys = post["attachments"]?["media_keys"]?.arrayValue {
            for key in keys { append(key.stringValue) }
        }
        return output
    }

    private static func collectMedia(
        in value: JSONValue,
        allowedIDs: Set<String>?,
        candidates: inout [(String?, URL, String?)]
    ) {
        switch value {
        case .object(let object):
            let type = object["type"]?.stringValue?.lowercased()
            let urlString = object["url"]?.stringValue ?? object["media_url_https"]?.stringValue
            if let urlString, let url = URL(string: urlString), isLikelyImage(url: url, type: type) {
                let id = object["media_key"]?.stringValue ?? object["media_id"]?.stringValue ?? object["id"]?.stringValue
                if allowedIDs == nil || id.map(allowedIDs!.contains) == true {
                    let alt = object["alt_text"]?.stringValue
                    candidates.append((id, url, alt))
                }
            }
            for key in object.keys.sorted() {
                collectMedia(in: object[key]!, allowedIDs: allowedIDs, candidates: &candidates)
            }
        case .array(let array):
            for child in array { collectMedia(in: child, allowedIDs: allowedIDs, candidates: &candidates) }
        default:
            break
        }
    }

    private static func isLikelyImage(url: URL, type: String?) -> Bool {
        if type == "photo" || type == "image" { return true }
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("twimg.com") { return true }
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "gif"].contains(ext)
    }

    private static func deriveTitle(from blocks: [CanonicalBlock]) -> String {
        let candidate = blocks.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text ?? "未命名文章"
        let firstLine = candidate.components(separatedBy: .newlines).first ?? candidate
        let sentence = firstLine.components(separatedBy: CharacterSet(charactersIn: "。！？.!?" )).first ?? firstLine
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "未命名文章" : trimmed).prefix(60))
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.date(from: value)
    }

    private struct ThreadPost {
        var id: String
        var conversationID: String
        var text: String
        var createdAt: Date
        var repliedTo: [String]
        var raw: JSONValue
    }

    private static func compareSnowflakes(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.count != rhs.count { return lhs.count < rhs.count }
        return lhs < rhs
    }
}
