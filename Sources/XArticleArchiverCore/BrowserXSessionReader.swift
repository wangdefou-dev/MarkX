import Foundation
import Security
import SQLite3

public struct BrowserSessionDefinition: Sendable, Equatable {
    public enum Engine: Sendable, Equatable { case chromium, firefox }
    public var id: String
    public var name: String
    public var bundleIdentifier: String
    public var relativeRoot: String
    public var account: String
    public var service: String
    public var engine: Engine = .chromium
    public static let chrome = BrowserSessionDefinition(id: "chrome", name: "Chrome", bundleIdentifier: "com.google.Chrome", relativeRoot: "Google/Chrome", account: "Chrome", service: "Chrome Safe Storage")
    public static let supported: [Self] = [
        .chrome,
        .init(id: "edge", name: "Edge", bundleIdentifier: "com.microsoft.edgemac", relativeRoot: "Microsoft Edge", account: "Microsoft Edge", service: "Microsoft Edge Safe Storage"),
        .init(id: "brave", name: "Brave", bundleIdentifier: "com.brave.Browser", relativeRoot: "BraveSoftware/Brave-Browser", account: "Brave", service: "Brave Safe Storage"),
        .init(id: "arc", name: "Arc", bundleIdentifier: "company.thebrowser.Browser", relativeRoot: "Arc/User Data", account: "Arc", service: "Arc Safe Storage"),
        .init(id: "vivaldi", name: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi", relativeRoot: "Vivaldi", account: "Vivaldi", service: "Vivaldi Safe Storage"),
        .init(id: "opera", name: "Opera", bundleIdentifier: "com.operasoftware.Opera", relativeRoot: "com.operasoftware.Opera", account: "Opera", service: "Opera Safe Storage"),
        .init(id: "chromium", name: "Chromium", bundleIdentifier: "org.chromium.Chromium", relativeRoot: "Chromium", account: "Chromium", service: "Chromium Safe Storage"),
        .init(id: "canary", name: "Chrome Canary", bundleIdentifier: "com.google.Chrome.canary", relativeRoot: "Google/Chrome Canary", account: "Chrome", service: "Chrome Safe Storage"),
        .init(id: "quark", name: "夸克", bundleIdentifier: "com.quark.desktop", relativeRoot: "Quark", account: "Quark Key", service: "Quark Safe Storage"),
        .init(id: "doubao", name: "豆包浏览器", bundleIdentifier: "com.bot.pc.doubao.browser", relativeRoot: "Doubao", account: "Doubao Browser", service: "Doubao Browser Safe Storage"),
        .init(id: "firefox", name: "Firefox", bundleIdentifier: "org.mozilla.firefox", relativeRoot: "Firefox", account: "", service: "", engine: .firefox)
    ]
    public func root(home: URL) -> URL { home.appending(path: "Library/Application Support/" + relativeRoot) }
}

public struct BrowserSessionProfile: Sendable, Identifiable {
    public var id: String { browser.id + ":" + databaseURL.path }
    public var browser: BrowserSessionDefinition
    public var name: String
    public var databaseURL: URL
    public var hasLoginCookies: Bool
    public var description: String { "\(browser.name) · \(name)" }
}

public struct BrowserSessionIssue: Sendable {
    public var browserName: String
    public var root: URL
    public var detail: String
}

public struct BrowserSessionProbe: Sendable {
    public init() {}
    public var profiles: [BrowserSessionProfile] = []
    public var issues: [BrowserSessionIssue] = []
    public var loggedInProfiles: [BrowserSessionProfile] { profiles.filter(\.hasLoginCookies) }
    public var summary: String {
        if let first = loggedInProfiles.first { return "已检测到 X 登录数据：\(first.description)" }
        if let first = issues.first { return "\(first.browserName) 数据读取受限：\(first.detail)" }
        return profiles.isEmpty ? "未发现可读取的浏览器配置，可手动选择数据目录。" : "已找到浏览器配置，尚未发现有效的 X 登录数据。"
    }
}

public enum BrowserSessionError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { if case .unavailable(let message) = self { message } else { nil } }
}

/// Discovery reads only X authentication-cookie metadata. Decryption is deferred
/// until import; browser passwords and unrelated website cookies are excluded.
public enum BrowserXSessionReader {
    static let hosts = [".x.com", "x.com", ".twitter.com", "twitter.com"]
    static let names = ["auth_token", "ct0", "twid", "kdt", "cf_clearance", "__cf_bm", "guest_id", "guest_id_ads", "guest_id_marketing", "personalization_id", "lang", "_twitter_sess"]

    public static func probe(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             browsers: [BrowserSessionDefinition] = BrowserSessionDefinition.supported,
                             customRoots: [String: URL] = [:]) -> BrowserSessionProbe {
        var result = BrowserSessionProbe()
        for browser in browsers {
            let root = customRoots[browser.id] ?? browser.root(home: home)
            do {
                guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                let candidates = try profileDirectories(root: root, engine: browser.engine)
                for (directory, name) in candidates {
                    let files = browser.engine == .firefox ? ["cookies.sqlite"] : ["Network/Cookies", "Cookies"]
                    for file in files {
                        let url = directory.appending(path: file)
                        do {
                            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                            let hasLogin = try hasAuthentication(databaseURL: url, engine: browser.engine)
                            result.profiles.append(.init(browser: browser, name: name, databaseURL: url, hasLoginCookies: hasLogin))
                        } catch where isMissing(error) { continue }
                        catch { result.issues.append(.init(browserName: browser.name, root: root, detail: readableError(error))) }
                    }
                }
            } catch where isMissing(error) { continue }
            catch { result.issues.append(.init(browserName: browser.name, root: root, detail: readableError(error))) }
        }
        return result
    }

    public static func readActiveSession(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                         browsers: [BrowserSessionDefinition] = BrowserSessionDefinition.supported,
                                         customRoots: [String: URL] = [:], preferredBrowserID: String? = nil,
                                         password: ((BrowserSessionDefinition) throws -> Data)? = nil) throws -> ChromeXSession {
        let selected: [BrowserSessionDefinition]
        if let preferredBrowserID {
            guard let browser = browsers.first(where: { $0.id == preferredBrowserID }) else {
                throw BrowserSessionError.unavailable("所选浏览器暂不受支持，请在设置中重新选择来源。")
            }
            selected = [browser]
        } else { selected = browsers }
        let probe = probe(home: home, browsers: selected, customRoots: customRoots)
        var failures: [String] = []
        var passwords: [String: Data] = [:]
        for profile in probe.loggedInProfiles {
            do {
                let session: ChromeXSession
                if profile.browser.engine == .firefox {
                    session = try readFirefox(profile)
                } else {
                    let key: Data
                    if let saved = passwords[profile.browser.id] { key = saved }
                    else {
                        key = try password?(profile.browser) ?? safeStoragePassword(profile.browser)
                        passwords[profile.browser.id] = key
                    }
                    session = try ChromeXSessionReader.readSession(databaseURL: profile.databaseURL, profileName: profile.name, safeStoragePassword: key)
                }
                var sourced = session
                sourced.browserName = profile.browser.name
                sourced.browserBundleIdentifier = profile.browser.bundleIdentifier
                return sourced
            } catch { failures.append("\(profile.description)：\(error.localizedDescription)") }
        }
        if let failure = failures.first { throw BrowserSessionError.unavailable("已找到 X 登录记录，但无法导入。\(failure)；请检查数据访问或钥匙串权限，无需重新登录 X。") }
        if let issue = probe.issues.first { throw BrowserSessionError.unavailable("\(issue.browserName) 数据无法读取：\(issue.detail)。请在设置中选择浏览器数据目录授权读取，无需重新登录 X。") }
        throw BrowserSessionError.unavailable(probe.summary)
    }

    static func profileDirectories(root: URL, engine: BrowserSessionDefinition.Engine) throws -> [(URL, String)] {
        if engine == .firefox {
            if FileManager.default.fileExists(atPath: root.appending(path: "cookies.sqlite").path) { return [(root, root.lastPathComponent)] }
            let profilesRoot = root.appending(path: "Profiles")
            let contents = try FileManager.default.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.map { ($0, $0.lastPathComponent) }
        }
        var order: [String] = []
        var displayNames: [String: String] = [:]
        if let data = try? Data(contentsOf: root.appending(path: "Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = json["profile"] as? [String: Any] {
            if let last = profile["last_used"] as? String, safeDirectory(last) { order.append(last) }
            if let cache = profile["info_cache"] as? [String: [String: Any]] {
                for key in cache.keys.sorted() where safeDirectory(key) {
                    order.append(key)
                    displayNames[key] = cache[key]?["name"] as? String
                }
            }
        }
        order.append("Default")
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        order += children.filter { $0.lastPathComponent.hasPrefix("Profile ") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.lastPathComponent).sorted()
        var seen = Set<String>()
        var result = order.filter { seen.insert($0).inserted }.map { (root.appending(path: $0), displayNames[$0] ?? $0) }
        result.append((root, "默认配置")) // Opera and manually selected profile directories.
        return result
    }

    static func safeDirectory(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }

    static func hasAuthentication(databaseURL: URL, engine: BrowserSessionDefinition.Engine) throws -> Bool {
        try withDatabase(databaseURL) { db in
            let chromium = engine == .chromium
            let columns = tableColumns(db, table: chromium ? "cookies" : "moz_cookies")
            let partition = chromium && columns.contains("top_frame_site_key") ? " AND top_frame_site_key = ''" : ""
            let now = Date().timeIntervalSince1970
            let expiry = chromium ? "(expires_utc = 0 OR expires_utc > \(Int64((now + 11_644_473_600) * 1_000_000)))" : "(expiry = 0 OR expiry > \(Int64(now)))"
            let nonempty = chromium ? "(length(value) > 0 OR length(encrypted_value) > 0)" : "length(value) > 0"
            let host = chromium ? "host_key" : "host"
            let group = !chromium && columns.contains("originAttributes") ? " GROUP BY originAttributes" : ""
            let sql = "SELECT count(DISTINCT name) FROM \(chromium ? "cookies" : "moz_cookies") WHERE \(host) IN ('.x.com','x.com') AND name IN ('auth_token','ct0') AND \(expiry) AND \(nonempty)\(partition)\(group)"
            let statement = try prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                if sqlite3_column_int(statement, 0) == 2 { return true }
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw databaseError(db) }
            return false
        }
    }

    static func readFirefox(_ profile: BrowserSessionProfile) throws -> ChromeXSession {
        try withDatabase(profile.databaseURL) { db in
            let columns = tableColumns(db, table: "moz_cookies")
            let origin = columns.contains("originAttributes") ? "originAttributes" : "''"
            let statement = try prepare(db, "SELECT host,name,value,path,expiry,isSecure,isHttpOnly,\(origin) FROM moz_cookies WHERE host IN ('.x.com','x.com','.twitter.com','twitter.com') AND name IN (\(names.map { "'\($0)'" }.joined(separator: ",")))")
            defer { sqlite3_finalize(statement) }
            var groups: [String: [HTTPCookie]] = [:]
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                defer { step = sqlite3_step(statement) }
                let expiry = sqlite3_column_int64(statement, 4)
                guard expiry == 0 || Double(expiry) > Date().timeIntervalSince1970 else { continue }
                let value = text(statement, 2)
                guard !value.isEmpty else { continue }
                var props: [HTTPCookiePropertyKey: Any] = [.domain: text(statement, 0), .name: text(statement, 1), .value: value, .path: text(statement, 3)]
                if sqlite3_column_int(statement, 5) != 0 { props[.secure] = "TRUE" }
                if sqlite3_column_int(statement, 6) != 0 { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                if expiry > 0 { props[.expires] = Date(timeIntervalSince1970: Double(expiry)) }
                if let cookie = HTTPCookie(properties: props) { groups[text(statement, 7), default: []].append(cookie) }
            }
            guard step == SQLITE_DONE else { throw databaseError(db) }
            for key in groups.keys.sorted(by: { $0.isEmpty ? !$1.isEmpty : !$1.isEmpty && $0 < $1 }) {
                let cookies = groups[key] ?? []
                if cookies.contains(where: { $0.name == "auth_token" && ["x.com", ".x.com"].contains($0.domain) }) && cookies.contains(where: { $0.name == "ct0" && ["x.com", ".x.com"].contains($0.domain) }) {
                    return ChromeXSession(profileName: profile.name, cookies: cookies)
                }
            }
            throw BrowserSessionError.unavailable("该 Firefox 配置没有完整的 X 登录会话")
        }
    }

    static func safeStoragePassword(_ browser: BrowserSessionDefinition) throws -> Data {
        guard let value = try KeychainStore.read(account: browser.account, service: browser.service), !value.isEmpty else {
            throw BrowserSessionError.unavailable("未能读取 \(browser.name) 的系统钥匙串密钥")
        }
        return Data(value.utf8)
    }

    static func withDatabase<T>(_ url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database = db else {
            if let db { sqlite3_close(db) }
            throw BrowserSessionError.unavailable("浏览器数据无法打开（\(status)），可能受到 macOS 访问权限限制")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_500)
        return try body(database)
    }

    static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError(db) }
        return statement
    }

    static func tableColumns(_ db: OpaquePointer, table: String) -> Set<String> {
        guard let statement = try? prepare(db, "PRAGMA table_info(\(table))") else { return [] }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { columns.insert(text(statement, 1)) }
        return columns
    }

    static func databaseError(_ db: OpaquePointer) -> BrowserSessionError { .unavailable("浏览器数据库读取失败（\(sqlite3_errcode(db))）") }
    static func text(_ statement: OpaquePointer, _ index: Int32) -> String { sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "" }
    static func isMissing(_ error: Error) -> Bool {
        let e = error as NSError
        return (e.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(e.code)) || (e.domain == NSPOSIXErrorDomain && e.code == 2)
    }
    static func readableError(_ error: Error) -> String {
        let e = error as NSError
        if (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError) || (e.domain == NSPOSIXErrorDomain && [1, 13].contains(e.code)) { return "macOS 尚未允许读取此目录" }
        return error is BrowserSessionError ? error.localizedDescription : "读取配置失败（\(e.code)）"
    }
}
