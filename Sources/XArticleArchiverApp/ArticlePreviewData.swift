import Foundation
import ImageIO
import XArticleArchiverCore

struct ArticlePreviewData: Sendable {
    var document: CanonicalDocument?
    var markdown: String

    nonisolated static func load(article: ArchivedArticle, root: URL?) -> Self {
        guard !Task.isCancelled else { return Self(document: nil, markdown: "") }
        let document = root.flatMap { AppViewModel.previewDocument(for: article, root: $0) }
        let markdown = article.markdownPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "无法读取本地 Markdown。"
        return Self(document: document, markdown: markdown)
    }
}

actor ArticleThumbnailCache {
    static let shared = ArticleThumbnailCache()
    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    func image(path: String) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let url = URL(fileURLWithPath: path)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(path):\(modified)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
