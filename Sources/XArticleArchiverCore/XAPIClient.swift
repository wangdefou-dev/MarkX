import Foundation

public enum XAPIError: LocalizedError, Sendable {
    case missingToken
    case invalidResponse
    case unauthorized
    case forbidden(String)
    case rateLimited(Date?)
    case quotaExceeded
    case notFound
    case server(Int)
    case api(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingToken: "还没有配置 X API Bearer Token"
        case .invalidResponse: "X API 返回了无法识别的响应"
        case .unauthorized: "X API 凭证无效或已经过期"
        case .forbidden(let detail): "当前 X API 权限不足：\(detail)"
        case .rateLimited(let date):
            if let date { "X API 请求过快，可在 \(date.formatted(date: .omitted, time: .standard)) 后继续" }
            else { "X API 请求过快，请稍后继续" }
        case .quotaExceeded: "X API 当前用量或余额不足"
        case .notFound: "没有找到该 X 账号或内容"
        case .server(let code): "X API 服务暂时异常（\(code)）"
        case .api(let code, let detail): "X API 请求失败（\(code)）：\(detail)"
        }
    }
}

public struct XAPIClient: Sendable {
    public var bearerToken: String
    public var baseURL: URL
    private let session: URLSession

    public init(
        bearerToken: String,
        baseURL: URL = URL(string: "https://api.x.com")!,
        session: URLSession = .shared
    ) {
        self.bearerToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        self.session = session
    }

    public func testConnection() async throws {
        guard !bearerToken.isEmpty else { throw XAPIError.missingToken }
        var components = URLComponents(url: baseURL.appending(path: "/2/users/by/username/XDevelopers"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user.fields", value: "id,name,username,protected")]
        _ = try await request(components.url!) as UserLookupResponse
    }

    public func lookupCreator(username: String) async throws -> Creator {
        guard !bearerToken.isEmpty else { throw XAPIError.missingToken }
        guard let normalized = HandleParser.normalize(username) else {
            throw XAPIError.api(0, "账号格式不正确")
        }
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
        var components = URLComponents(url: baseURL.appending(path: "/2/users/by/username/\(encoded)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user.fields", value: "id,name,username,protected,profile_image_url")]
        let response: UserLookupResponse = try await request(components.url!)
        return Creator(
            xUserID: response.data.id,
            username: response.data.username,
            displayName: response.data.name,
            profileImageURL: response.data.profileImageURL.flatMap(URL.init(string:)),
            isProtected: response.data.protected ?? false
        )
    }

    /// Uses the paid timeline only to discover which Posts own an X Article.
    /// Article images and author expansions are deliberately omitted: the
    /// rendered page capture supplies the body and media later.
    public func discoverRecentArticles(
        for creator: Creator,
        sinceID: String? = nil,
        maximumArticles: Int? = nil,
        maximumScannedPosts: Int = 300,
        progress: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> ArticleReferenceDiscoveryResult {
        guard !bearerToken.isEmpty else { throw XAPIError.missingToken }
        if let maximumArticles, maximumArticles < 1 {
            return ArticleReferenceDiscoveryResult(
                articles: [], scannedPosts: 0, newestPostID: nil,
                oldestPostID: nil, completeness: .partial
            )
        }

        let scanLimit = min(3_200, max(5, maximumScannedPosts))
        var paginationToken: String?
        var scanned = 0
        var references: [ArticleReference] = []
        var newest: String?
        var oldest: String?
        var stoppedAtRequestedCount = false

        repeat {
            let remaining = scanLimit - scanned
            guard remaining >= 5 else { break }
            let economicalPageSize = maximumArticles.map { max(5, min(100, $0 * 2)) } ?? 100
            let pageSize = min(100, max(5, min(remaining, economicalPageSize)))
            var components = URLComponents(
                url: baseURL.appending(path: "/2/users/\(creator.xUserID)/tweets"),
                resolvingAgainstBaseURL: false
            )!
            var items = articleDiscoveryQueryItems
            items.append(URLQueryItem(name: "max_results", value: String(pageSize)))
            if let paginationToken { items.append(URLQueryItem(name: "pagination_token", value: paginationToken)) }
            if let sinceID { items.append(URLQueryItem(name: "since_id", value: sinceID)) }
            components.queryItems = items

            let page: DynamicPostsResponse = try await request(components.url!)
            references.append(contentsOf: decodeArticleReferences(posts: page.data ?? [], creator: creator))
            references = deduplicate(references)
            scanned += page.meta?["result_count"]?.intValue ?? page.data?.count ?? 0
            newest = newest ?? page.meta?["newest_id"]?.stringValue
            oldest = page.meta?["oldest_id"]?.stringValue ?? oldest
            paginationToken = page.meta?["next_token"]?.stringValue
            await progress?(scanned)
            if let maximumArticles, references.count >= maximumArticles {
                stoppedAtRequestedCount = true
                break
            }
        } while paginationToken != nil && scanned < scanLimit

        references.sort(by: articleReferenceOrder)
        if let maximumArticles { references = Array(references.prefix(maximumArticles)) }
        let hasUnscannedPage = paginationToken != nil
        return ArticleReferenceDiscoveryResult(
            articles: references,
            scannedPosts: scanned,
            newestPostID: newest,
            oldestPostID: oldest,
            completeness: (stoppedAtRequestedCount || scanned >= scanLimit) && hasUnscannedPage
                ? .partial
                : .recentWindowComplete
        )
    }

    public func discoverFullArchiveArticles(
        for creator: Creator,
        startDate: Date,
        endDate: Date,
        progress: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> ArticleReferenceDiscoveryResult {
        guard !bearerToken.isEmpty else { throw XAPIError.missingToken }
        var nextToken: String?
        var scanned = 0
        var references: [ArticleReference] = []
        var newest: String?
        var oldest: String?
        let formatter = ISO8601DateFormatter()

        repeat {
            var components = URLComponents(
                url: baseURL.appending(path: "/2/tweets/search/all"),
                resolvingAgainstBaseURL: false
            )!
            var items = articleDiscoveryQueryItems
            items.append(URLQueryItem(name: "query", value: "from:\(creator.username) -is:retweet"))
            items.append(URLQueryItem(name: "start_time", value: formatter.string(from: startDate)))
            items.append(URLQueryItem(name: "end_time", value: formatter.string(from: endDate)))
            items.append(URLQueryItem(name: "max_results", value: "500"))
            if let nextToken { items.append(URLQueryItem(name: "next_token", value: nextToken)) }
            components.queryItems = items

            let page: DynamicPostsResponse = try await request(components.url!)
            references.append(contentsOf: decodeArticleReferences(posts: page.data ?? [], creator: creator))
            scanned += page.meta?["result_count"]?.intValue ?? page.data?.count ?? 0
            newest = newest ?? page.meta?["newest_id"]?.stringValue
            oldest = page.meta?["oldest_id"]?.stringValue ?? oldest
            nextToken = page.meta?["next_token"]?.stringValue
            await progress?(scanned)
        } while nextToken != nil

        references = deduplicate(references).sorted(by: articleReferenceOrder)
        return ArticleReferenceDiscoveryResult(
            articles: references,
            scannedPosts: scanned,
            newestPostID: newest,
            oldestPostID: oldest,
            completeness: .fullArchiveVerified
        )
    }

    public func fetchRecentLongform(
        for creator: Creator,
        sinceID: String? = nil,
        maximumArticles: Int? = nil,
        maximumScannedPosts: Int = 300,
        progress: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> DiscoveryResult {
        guard !bearerToken.isEmpty else { throw XAPIError.missingToken }
        if let maximumArticles, maximumArticles < 1 {
            return DiscoveryResult(
                documents: [],
                scannedPosts: 0,
                newestPostID: nil,
                oldestPostID: nil,
                completeness: .partial
            )
        }
        let scanLimit = min(3_200, max(5, maximumScannedPosts))
        var paginationToken: String?
        var scanned = 0
        var rawPosts: [JSONValue] = []
        var mergedIncludes: [JSONValue] = []
        var newest: String?
        var oldest: String?
        var stoppedAtRequestedCount = false

        repeat {
            let remaining = scanLimit - scanned
            guard remaining >= 5 else { break }
            let economicalPageSize: Int
            if let maximumArticles {
                // Reads are billed per returned Post, not per request. Smaller
                // pages sharply reduce the otherwise wasted final-page scan.
                economicalPageSize = max(5, min(100, maximumArticles * 2))
            } else {
                economicalPageSize = 100
            }
            let pageSize = min(100, max(5, min(remaining, economicalPageSize)))
            var components = URLComponents(url: baseURL.appending(path: "/2/users/\(creator.xUserID)/tweets"), resolvingAgainstBaseURL: false)!
            var items = standardQueryItems
            items.append(URLQueryItem(name: "max_results", value: String(pageSize)))
            if let paginationToken { items.append(URLQueryItem(name: "pagination_token", value: paginationToken)) }
            if let sinceID { items.append(URLQueryItem(name: "since_id", value: sinceID)) }
            components.queryItems = items

            let page: DynamicPostsResponse = try await request(components.url!)
            rawPosts.append(contentsOf: page.data ?? [])
            if let includes = page.includes { mergedIncludes.append(includes) }
            scanned += page.meta?["result_count"]?.intValue ?? page.data?.count ?? 0
            newest = newest ?? page.meta?["newest_id"]?.stringValue
            oldest = page.meta?["oldest_id"]?.stringValue ?? oldest
            paginationToken = page.meta?["next_token"]?.stringValue
            await progress?(scanned)
            if let maximumArticles {
                let current = try decodeArticles(posts: rawPosts, mergedIncludes: mergedIncludes, creator: creator)
                if current.count >= maximumArticles {
                    stoppedAtRequestedCount = true
                    break
                }
            }
        } while paginationToken != nil && scanned < scanLimit

        var documents = try decodeArticles(posts: rawPosts, mergedIncludes: mergedIncludes, creator: creator)
        if let maximumArticles { documents = Array(documents.prefix(maximumArticles)) }
        let hasUnscannedPage = paginationToken != nil
        return DiscoveryResult(
            documents: documents,
            scannedPosts: scanned,
            newestPostID: newest,
            oldestPostID: oldest,
            completeness: (stoppedAtRequestedCount || scanned >= scanLimit) && hasUnscannedPage
                ? .partial
                : .recentWindowComplete
        )
    }

    /// Retrieves only the explicitly requested Posts. It deliberately omits
    /// `author_id` expansion: the Post already includes the author's numeric
    /// ID and the status link supplies the handle, avoiding a separately
    /// billable User resource for this path.
    public func fetchArticles(links: [XArticleLink]) async throws -> DirectArticleFetchResult {
        guard !bearerToken.isEmpty else { throw XAPIError.missingToken }
        guard !links.isEmpty else {
            return DirectArticleFetchResult(items: [], nonArticleLinks: [], unavailableLinks: [], fetchedPosts: 0)
        }

        var postsByID: [String: JSONValue] = [:]
        var includesByPostID: [String: JSONValue] = [:]
        var fetchedPosts = 0

        for start in stride(from: 0, to: links.count, by: 100) {
            let end = min(start + 100, links.count)
            let chunk = Array(links[start..<end])
            var components = URLComponents(url: baseURL.appending(path: "/2/tweets"), resolvingAgainstBaseURL: false)!
            var items = directLookupQueryItems
            items.append(URLQueryItem(name: "ids", value: chunk.map(\.postID).joined(separator: ",")))
            components.queryItems = items

            let response: DynamicPostsResponse = try await request(components.url!)
            let includes = response.includes
            for post in response.data ?? [] {
                guard let postID = post["id"]?.stringValue else { continue }
                postsByID[postID] = post
                if let includes { includesByPostID[postID] = includes }
                fetchedPosts += 1
            }
        }

        var output: [DirectArticleItem] = []
        var nonArticles: [XArticleLink] = []
        var unavailable: [XArticleLink] = []
        for link in links {
            guard let post = postsByID[link.postID] else {
                unavailable.append(link)
                continue
            }
            guard post["article"] != nil else {
                nonArticles.append(link)
                continue
            }
            guard let authorID = post["author_id"]?.stringValue else {
                throw XAPIError.api(200, "文章 \(link.postID) 缺少 author_id，无法安全归档到对应作者")
            }
            let creator = Creator(
                xUserID: authorID,
                username: link.username,
                displayName: "@\(link.username)"
            )
            guard let document = try XContentDecoder.decode(
                RawPostEnvelope(post: post, includes: includesByPostID[link.postID]),
                creator: creator
            ) else {
                throw XAPIError.api(200, "文章 \(link.postID) 缺少可归档的完整正文")
            }
            output.append(DirectArticleItem(creator: creator, document: document, link: link))
        }

        return DirectArticleFetchResult(
            items: output,
            nonArticleLinks: nonArticles,
            unavailableLinks: unavailable,
            fetchedPosts: fetchedPosts
        )
    }

    public func fetchFullArchiveLongform(
        for creator: Creator,
        startDate: Date,
        endDate: Date,
        progress: (@Sendable (Int) async -> Void)? = nil
    ) async throws -> DiscoveryResult {
        guard !bearerToken.isEmpty else { throw XAPIError.missingToken }
        var nextToken: String?
        var scanned = 0
        var rawPosts: [JSONValue] = []
        var mergedIncludes: [JSONValue] = []
        var newest: String?
        var oldest: String?
        let formatter = ISO8601DateFormatter()

        repeat {
            var components = URLComponents(url: baseURL.appending(path: "/2/tweets/search/all"), resolvingAgainstBaseURL: false)!
            var items = standardQueryItems
            items.append(URLQueryItem(name: "query", value: "from:\(creator.username) -is:retweet"))
            items.append(URLQueryItem(name: "start_time", value: formatter.string(from: startDate)))
            items.append(URLQueryItem(name: "end_time", value: formatter.string(from: endDate)))
            items.append(URLQueryItem(name: "max_results", value: "500"))
            if let nextToken { items.append(URLQueryItem(name: "next_token", value: nextToken)) }
            components.queryItems = items

            let page: DynamicPostsResponse = try await request(components.url!)
            rawPosts.append(contentsOf: page.data ?? [])
            if let includes = page.includes { mergedIncludes.append(includes) }
            scanned += page.meta?["result_count"]?.intValue ?? page.data?.count ?? 0
            newest = newest ?? page.meta?["newest_id"]?.stringValue
            oldest = page.meta?["oldest_id"]?.stringValue ?? oldest
            nextToken = page.meta?["next_token"]?.stringValue
            await progress?(scanned)
        } while nextToken != nil

        return DiscoveryResult(
            documents: try decodeArticles(posts: rawPosts, mergedIncludes: mergedIncludes, creator: creator),
            scannedPosts: scanned,
            newestPostID: newest,
            oldestPostID: oldest,
            completeness: .fullArchiveVerified
        )
    }

    private var standardQueryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "tweet.fields", value: "article,article_title,attachments,author_id,created_at,edit_history_tweet_ids,text"),
            URLQueryItem(name: "expansions", value: "article.cover_media,article.media_entities,attachments.media_keys,author_id"),
            URLQueryItem(name: "media.fields", value: "alt_text,height,media_key,preview_image_url,type,url,variants,width"),
            URLQueryItem(name: "user.fields", value: "id,name,username,protected,profile_image_url")
        ]
    }

    private var articleDiscoveryQueryItems: [URLQueryItem] {
        [
            URLQueryItem(
                name: "tweet.fields",
                value: "article,article_title,author_id,created_at,edit_history_tweet_ids"
            )
        ]
    }

    private var directLookupQueryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "tweet.fields", value: "article,article_title,attachments,author_id,created_at,edit_history_tweet_ids,text"),
            URLQueryItem(name: "expansions", value: "article.cover_media,article.media_entities,attachments.media_keys"),
            URLQueryItem(name: "media.fields", value: "alt_text,height,media_key,preview_image_url,type,url,variants,width")
        ]
    }

    private func request<Response: Decodable>(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.problemDetail(from: data)
            switch http.statusCode {
            case 401: throw XAPIError.unauthorized
            case 402: throw XAPIError.quotaExceeded
            case 403: throw XAPIError.forbidden(detail)
            case 404: throw XAPIError.notFound
            case 429:
                let reset = http.value(forHTTPHeaderField: "x-rate-limit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                throw XAPIError.rateLimited(reset)
            case 500...599: throw XAPIError.server(http.statusCode)
            default: throw XAPIError.api(http.statusCode, detail)
            }
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw XAPIError.api(http.statusCode, "响应结构无法解析：\(error.localizedDescription)")
        }
    }

    private static func problemDetail(from data: Data) -> String {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return "未知错误" }
        return root.firstString(forKeys: ["detail", "title", "message"]) ?? "未知错误"
    }

    private func mergeIncludes(_ values: [JSONValue]) -> JSONValue? {
        guard !values.isEmpty else { return nil }
        var result: [String: [JSONValue]] = [:]
        for value in values {
            guard let object = value.objectValue else { continue }
            for (key, child) in object {
                if let array = child.arrayValue { result[key, default: []].append(contentsOf: array) }
            }
        }
        return .object(result.mapValues(JSONValue.array))
    }

    private func deduplicate(_ documents: [CanonicalDocument]) -> [CanonicalDocument] {
        var seen = Set<String>()
        return documents.filter {
            let key = $0.sourceArticleID ?? $0.sourcePostID
            return seen.insert(key).inserted
        }
    }

    private func deduplicate(_ references: [ArticleReference]) -> [ArticleReference] {
        var seen = Set<String>()
        return references.filter { seen.insert($0.postID).inserted }
    }

    private func decodeArticleReferences(posts: [JSONValue], creator: Creator) -> [ArticleReference] {
        posts.compactMap { post in
            guard let postID = post["id"]?.stringValue,
                  let article = post["article"],
                  article.objectValue != nil else { return nil }
            let title = article.firstString(forKeys: ["title"])
                ?? post["article_title"]?.firstString(forKeys: ["title", "text"])
                ?? "X Article \(postID.suffix(8))"
            return ArticleReference(
                postID: postID,
                articleID: article.firstString(forKeys: ["id", "article_id"]),
                title: title,
                publishedAt: parseArticleDate(post["created_at"]?.stringValue) ?? Date(),
                sourceURL: URL(string: "https://x.com/\(creator.username)/status/\(postID)")!,
                expectedPlainText: article["plain_text"]?.stringValue
            )
        }
    }

    private func articleReferenceOrder(_ left: ArticleReference, _ right: ArticleReference) -> Bool {
        if left.publishedAt != right.publishedAt { return left.publishedAt > right.publishedAt }
        return left.postID > right.postID
    }

    private func parseArticleDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter.date(from: value)
    }

    private func decodeArticles(
        posts: [JSONValue],
        mergedIncludes: [JSONValue],
        creator: Creator
    ) throws -> [CanonicalDocument] {
        let includes = mergeIncludes(mergedIncludes)
        let articles = try posts.compactMap {
            try XContentDecoder.decode(RawPostEnvelope(post: $0, includes: includes), creator: creator)
        }
        return deduplicate(articles.filter { $0.contentType == .xArticle }).sorted { left, right in
            if left.publishedAt != right.publishedAt { return left.publishedAt > right.publishedAt }
            return left.sourcePostID > right.sourcePostID
        }
    }
}

private struct UserLookupResponse: Decodable {
    struct User: Decodable {
        var id: String
        var name: String
        var username: String
        var protected: Bool?
        var profileImageURL: String?

        enum CodingKeys: String, CodingKey {
            case id, name, username, protected
            case profileImageURL = "profile_image_url"
        }
    }
    var data: User
}

private struct DynamicPostsResponse: Decodable {
    var data: [JSONValue]?
    var includes: JSONValue?
    var meta: JSONValue?
}

public struct DirectArticleItem: Sendable {
    public var creator: Creator
    public var document: CanonicalDocument
    public var link: XArticleLink

    public init(creator: Creator, document: CanonicalDocument, link: XArticleLink) {
        self.creator = creator
        self.document = document
        self.link = link
    }
}

public struct DirectArticleFetchResult: Sendable {
    public var items: [DirectArticleItem]
    public var nonArticleLinks: [XArticleLink]
    public var unavailableLinks: [XArticleLink]
    public var fetchedPosts: Int

    public init(
        items: [DirectArticleItem],
        nonArticleLinks: [XArticleLink],
        unavailableLinks: [XArticleLink],
        fetchedPosts: Int
    ) {
        self.items = items
        self.nonArticleLinks = nonArticleLinks
        self.unavailableLinks = unavailableLinks
        self.fetchedPosts = fetchedPosts
    }
}

public struct ArticleReference: Hashable, Sendable {
    public var postID: String
    public var articleID: String?
    public var title: String
    public var publishedAt: Date
    public var sourceURL: URL
    public var expectedPlainText: String?

    public init(
        postID: String,
        articleID: String? = nil,
        title: String,
        publishedAt: Date,
        sourceURL: URL,
        expectedPlainText: String? = nil
    ) {
        self.postID = postID
        self.articleID = articleID
        self.title = title
        self.publishedAt = publishedAt
        self.sourceURL = sourceURL
        self.expectedPlainText = expectedPlainText
    }
}

public struct ArticleReferenceDiscoveryResult: Sendable {
    public var articles: [ArticleReference]
    public var scannedPosts: Int
    public var newestPostID: String?
    public var oldestPostID: String?
    public var completeness: CompletenessStatus

    public init(
        articles: [ArticleReference],
        scannedPosts: Int,
        newestPostID: String?,
        oldestPostID: String?,
        completeness: CompletenessStatus
    ) {
        self.articles = articles
        self.scannedPosts = scannedPosts
        self.newestPostID = newestPostID
        self.oldestPostID = oldestPostID
        self.completeness = completeness
    }
}
