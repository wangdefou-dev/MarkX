import Foundation
import XArticleArchiverCore

struct CreatorArticleDiscoveryRequest: Identifiable, Hashable {
    var id: String { username.lowercased() }
    var username: String
    var maximumArticles: Int?
    var resolvesTotalCount = false
    var countOnly = false

    var pageURL: URL {
        URL(string: "https://x.com/\(username)/articles")!
    }

    var scopeDescription: String {
        maximumArticles.map { "最近 \($0) 篇" } ?? "全部历史"
    }
}

struct CreatorArticleDiscoveryResult: Hashable {
    var items: [CreatorArticleListItem]
    var knownArticleCount: Int?
}

struct CreatorArticleListItem: Identifiable, Hashable {
    var id: String { link.postID }
    var link: XArticleLink
    var title: String

    var sourceURLText: String {
        "https://x.com/\(link.username)/status/\(link.postID)"
    }
}

struct DownloadResultNotice: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var message: String
}

enum BrowserCaptureArchiveOutcome: Hashable {
    case saved
    case failed
    case stopped
}

enum BackgroundDownloadItemState: Hashable {
    case queued
    case running
    case saved
    case subscriptionRequired
    case failed

    var title: String {
        switch self {
        case .queued: "等待下载"
        case .running: "正在保存完整排版"
        case .saved: "已保存"
        case .subscriptionRequired: "需要订阅"
        case .failed: "下载失败"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .saved: "checkmark.circle.fill"
        case .subscriptionRequired: "lock.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }
}

struct BrowserCaptureRequest: Identifiable, Hashable {
    var id: String { link.postID }
    var link: XArticleLink
    var creator: Creator
    var displayTitle: String
    var publishedAt: Date?
    var sourceArticleID: String?
    var expectedPlainText: String?

    init(
        link: XArticleLink,
        creator: Creator,
        displayTitle: String,
        publishedAt: Date? = nil,
        sourceArticleID: String? = nil,
        expectedPlainText: String? = nil
    ) {
        self.link = link
        self.creator = creator
        self.displayTitle = displayTitle
        self.publishedAt = publishedAt
        self.sourceArticleID = sourceArticleID
        self.expectedPlainText = expectedPlainText
    }
}
