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

enum DownloadResultMetricTone: String, Hashable {
    case accent
    case positive
    case neutral
    case warning
    case danger
}

struct DownloadResultMetric: Identifiable, Hashable {
    let id: String
    let label: String
    let value: String
    let systemImage: String
    let tone: DownloadResultMetricTone

    init(
        id: String,
        label: String,
        value: String,
        systemImage: String,
        tone: DownloadResultMetricTone = .neutral
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.systemImage = systemImage
        self.tone = tone
    }
}

struct DownloadResultNotice: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var message: String
    var metrics: [DownloadResultMetric]

    init(
        title: String,
        message: String,
        metrics: [DownloadResultMetric] = []
    ) {
        self.title = title
        self.message = message
        self.metrics = metrics
    }
}

enum BrowserCaptureArchiveOutcome: Hashable {
    case saved
    case failed
    case stopped
}

enum BackgroundDownloadItemState: Hashable {
    case queued
    case running
    case checking
    case saved
    case checked
    case subscriptionRequired
    case failed

    var title: String {
        switch self {
        case .queued: "等待下载"
        case .running: "正在保存完整排版"
        case .checking: "正在核对商单内容"
        case .saved: "已保存"
        case .checked: "已核对"
        case .subscriptionRequired: "需要订阅"
        case .failed: "下载失败"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .checking: "tag"
        case .saved: "checkmark.circle.fill"
        case .checked: "tag.fill"
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
    var disclosureOnly: Bool

    init(
        link: XArticleLink,
        creator: Creator,
        displayTitle: String,
        publishedAt: Date? = nil,
        sourceArticleID: String? = nil,
        expectedPlainText: String? = nil,
        disclosureOnly: Bool = false
    ) {
        self.link = link
        self.creator = creator
        self.displayTitle = displayTitle
        self.publishedAt = publishedAt
        self.sourceArticleID = sourceArticleID
        self.expectedPlainText = expectedPlainText
        self.disclosureOnly = disclosureOnly
    }
}
