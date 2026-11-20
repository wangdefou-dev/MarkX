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
    /// Other Keychain service names the same browser has used.
    public var alternateServices: [String] = []
    /// Found by scanning Application Support rather than listed here.
    public var isDiscovered = false
    public var keychainServices: [String] { ([service] + alternateServices).filter { !$0.isEmpty } }

    public static let chrome = BrowserSessionDefinition(id: "chrome", name: "Chrome", bundleIdentifier: "com.google.Chrome", relativeRoot: "Google/Chrome", account: "Chrome", service: "Chrome Safe Storage")
    private static func firefoxFamily(_ id: String, _ name: String, _ bundle: String, _ root: String) -> Self {
        .init(id: id, name: name, bundleIdentifier: bundle, relativeRoot: root, account: "", service: "", engine: .firefox)
    }
    public static let supported: [Self] = [
        .chrome,
        .init(id: "chrome-beta", name: "Chrome Beta", bundleIdentifier: "com.google.Chrome.beta", relativeRoot: "Google/Chrome Beta", account: "Chrome", service: "Chrome Safe Storage"),
        .init(id: "chrome-dev", name: "Chrome Dev", bundleIdentifier: "com.google.Chrome.dev", relativeRoot: "Google/Chrome Dev", account: "Chrome", service: "Chrome Safe Storage"),
        .init(id: "canary", name: "Chrome Canary", bundleIdentifier: "com.google.Chrome.canary", relativeRoot: "Google/Chrome Canary", account: "Chrome", service: "Chrome Safe Storage"),
        .init(id: "edge", name: "Edge", bundleIdentifier: "com.microsoft.edgemac", relativeRoot: "Microsoft Edge", account: "Microsoft Edge", service: "Microsoft Edge Safe Storage"),
        .init(id: "edge-beta", name: "Edge Beta", bundleIdentifier: "com.microsoft.edgemac.Beta", relativeRoot: "Microsoft Edge Beta", account: "Microsoft Edge", service: "Microsoft Edge Safe Storage"),
        .init(id: "edge-dev", name: "Edge Dev", bundleIdentifier: "com.microsoft.edgemac.Dev", relativeRoot: "Microsoft Edge Dev", account: "Microsoft Edge", service: "Microsoft Edge Safe Storage"),
        .init(id: "edge-canary", name: "Edge Canary", bundleIdentifier: "com.microsoft.edgemac.Canary", relativeRoot: "Microsoft Edge Canary", account: "Microsoft Edge", service: "Microsoft Edge Safe Storage"),
        .init(id: "brave", name: "Brave", bundleIdentifier: "com.brave.Browser", relativeRoot: "BraveSoftware/Brave-Browser", account: "Brave", service: "Brave Safe Storage", alternateServices: ["Brave Browser Safe Storage"]),
        .init(id: "brave-beta", name: "Brave Beta", bundleIdentifier: "com.brave.Browser.beta", relativeRoot: "BraveSoftware/Brave-Browser-Beta", account: "Brave", service: "Brave Safe Storage", alternateServices: ["Brave Browser Safe Storage"]),
        .init(id: "brave-nightly", name: "Brave Nightly", bundleIdentifier: "com.brave.Browser.nightly", relativeRoot: "BraveSoftware/Brave-Browser-Nightly", account: "Brave", service: "Brave Safe Storage", alternateServices: ["Brave Browser Safe Storage"]),
        .init(id: "arc", name: "Arc", bundleIdentifier: "company.thebrowser.Browser", relativeRoot: "Arc/User Data", account: "Arc", service: "Arc Safe Storage"),
        .init(id: "dia", name: "Dia", bundleIdentifier: "company.thebrowser.dia", relativeRoot: "Dia/User Data", account: "Dia", service: "Dia Safe Storage"),
        .init(id: "comet", name: "Comet", bundleIdentifier: "ai.perplexity.comet", relativeRoot: "Comet", account: "Comet", service: "Comet Safe Storage"),
        .init(id: "vivaldi", name: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi", relativeRoot: "Vivaldi", account: "Vivaldi", service: "Vivaldi Safe Storage"),
        .init(id: "opera", name: "Opera", bundleIdentifier: "com.operasoftware.Opera", relativeRoot: "com.operasoftware.Opera", account: "Opera", service: "Opera Safe Storage"),
        .init(id: "opera-gx", name: "Opera GX", bundleIdentifier: "com.operasoftware.OperaGX", relativeRoot: "com.operasoftware.OperaGX", account: "Opera", service: "Opera Safe Storage", alternateServices: ["Opera GX Safe Storage"]),
        .init(id: "yandex", name: "Yandex", bundleIdentifier: "ru.yandex.desktop.yandex-browser", relativeRoot: "Yandex/YandexBrowser", account: "Yandex", service: "Yandex Safe Storage"),
        .init(id: "chromium", name: "Chromium", bundleIdentifier: "org.chromium.Chromium", relativeRoot: "Chromium", account: "Chromium", service: "Chromium Safe Storage"),
        .init(id: "thorium", name: "Thorium", bundleIdentifier: "org.chromium.Thorium", relativeRoot: "Thorium", account: "Thorium", service: "Thorium Safe Storage", alternateServices: ["Chromium Safe Storage"]),
        .init(id: "quark", name: "夸克", bundleIdentifier: "com.quark.desktop", relativeRoot: "Quark", account: "Quark Key", service: "Quark Safe Storage"),
        .init(id: "doubao", name: "豆包浏览器", bundleIdentifier: "com.bot.pc.doubao.browser", relativeRoot: "Doubao", account: "Doubao Browser", service: "Doubao Browser Safe Storage"),
        firefoxFamily("firefox", "Firefox", "org.mozilla.firefox", "Firefox"),
        firefoxFamily("zen", "Zen", "app.zen-browser.zen", "zen"),
        firefoxFamily("librewolf", "LibreWolf", "org.mozilla.librewolf", "librewolf"),
        firefoxFamily("waterfox", "Waterfox", "net.waterfox.waterfox", "Waterfox"),
        firefoxFamily("floorp", "Floorp", "one.ablaze.floorp", "Floorp")
    ]
    public func root(home: URL) -> URL { home.appending(path: "Library/Application Support/" + relativeRoot) }

    /// Supported browsers plus any other Chromium browser found in
    /// Application Support (a folder with a `Local State` file).
    public static func all(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Self] {
        supported + discoveredChromium(home: home)
    }

    static func discoveredChromium(home: URL) -> [Self] {
        let fileManager = FileManager.default
        let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let known = Set(supported.map { $0.relativeRoot.lowercased() })
        func directories(_ url: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        var found: [Self] = []
        for first in directories(support) {
            for candidate in [first] + directories(first) {
                guard fileManager.fileExists(atPath: candidate.appending(path: "Local State").path) else { continue }
                let relative = String(candidate.standardizedFileURL.path.dropFirst(support.standardizedFileURL.path.count + 1))
                guard !known.contains(relative.lowercased()), !found.contains(where: { $0.relativeRoot == relative }) else { continue }
                let name = candidate.lastPathComponent == "User Data" ? candidate.deletingLastPathComponent().lastPathComponent : candidate.lastPathComponent
                var definition = Self(id: "auto:" + relative, name: name, bundleIdentifier: "", relativeRoot: relative, account: name, service: "\(name) Safe Storage")
                definition.isDiscovered = true
                found.append(definition)
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public struct BrowserSessionProfile: Sendable, Identifiable {
    public var id: String { browser.id + ":" + databaseURL.path }
    public var browser: BrowserSessionDefinition
    public var name: String
    public var databaseURL: URL
    public var hasLoginCookies: Bool
    /// Folder name of the profile inside the browser root (e.g. `Profile 2`).
    public var directoryName: String = ""
    /// Last change to the cookie database: the browser in use most recently.
    public var lastActivity: Date?
    public var description: String { "\(browser.name) · \(name)" }
    /// Stored as the preferred source to pin exactly this profile.
    public var selectionID: String { BrowserSessionSelection.profileID(browserID: browser.id, directory: directoryName) }
}

/// The user's chosen login source: automatic, one browser, or one profile
/// (`browserID|profileDirectory`).
public struct BrowserSessionSelection: Sendable, Equatable {
    public var browserID: String?
    public var profileDirectory: String?

    public static let automaticID = "automatic"

    public init(_ stored: String?) {
        guard let stored, !stored.isEmpty, stored != Self.automaticID else { return }
        let parts = stored.split(separator: "|", maxSplits: 1).map(String.init)
        browserID = parts[0]
        profileDirectory = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
    }

    public var isAutomatic: Bool { browserID == nil }

    public static func profileID(browserID: String, directory: String) -> String { "\(browserID)|\(directory)" }

    public func matches(_ profile: BrowserSessionProfile) -> Bool {
        guard let browserID else { return true }
        guard profile.browser.id == browserID else { return false }
        return profileDirectory == nil || profile.directoryName == profileDirectory
    }
}

public struct BrowserSessionIssue: Sendable {
    public var browserID: String = ""
    public var browserName: String
    public var root: URL
    public var detail: String
    /// macOS privacy protection blocked the read; the user can grant access by
    /// choosing the directory in an open panel.
    public var isPermissionDenied = false
}

public struct BrowserSessionProbe: Sendable {
    public init() {}
    public var profiles: [BrowserSessionProfile] = []
    public var issues: [BrowserSessionIssue] = []
    /// The user's chosen source; every browser is still probed so the
    /// settings can list all logins to switch between.
    public var selection = BrowserSessionSelection(nil)
    /// Every logged-in profile, most recently used first.
    public var loggedInProfiles: [BrowserSessionProfile] {
        profiles.enumerated()
            .filter { $0.element.hasLoginCookies }
            .sorted { lhs, rhs in
                let left = lhs.element.lastActivity ?? .distantPast
                let right = rhs.element.lastActivity ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
    }
    /// Logged-in profiles the chosen source allows, in the order they are tried.
    public var selectedProfiles: [BrowserSessionProfile] { loggedInProfiles.filter(selection.matches) }
    private var selectedIssues: [BrowserSessionIssue] {
        guard let browserID = selection.browserID else { return issues }
        return issues.filter { $0.browserID == browserID }
    }
    /// The first browser whose data macOS refused to read, when no readable
    /// profile already has an X login for the chosen source.
    public var browserNeedingAccess: BrowserSessionIssue? {
        selectedProfiles.isEmpty ? selectedIssues.first(where: \.isPermissionDenied) : nil
    }
    public var summary: String {
        if let first = selectedProfiles.first {
            let others = loggedInProfiles.count - 1
            return "将使用 \(first.description) 的 X 登录" + (others > 0 ? "（另有 \(others) 个登录可在“使用浏览器”中切换）" : "")
        }
        if let first = selectedIssues.first { return "\(first.browserName) 数据读取受限：\(first.detail)" }
        if !selection.isAutomatic, let other = loggedInProfiles.first {
            return "所选来源没有有效的 X 登录；\(other.description) 有登录，可在“使用浏览器”中切换"
        }
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
                    let directoryName = directory.standardizedFileURL.path == root.standardizedFileURL.path ? "" : directory.lastPathComponent
                    let files = browser.engine == .firefox ? ["cookies.sqlite"] : ["Network/Cookies", "Cookies"]
                    for file in files {
                        let url = directory.appending(path: file)
                        do {
                            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                            let hasLogin = try hasAuthentication(databaseURL: url, engine: browser.engine)
                            // Electron apps also keep Chromium data; list them only with an X login.
                            if browser.isDiscovered && !hasLogin { continue }
                            result.profiles.append(.init(browser: browser, name: name, databaseURL: url, hasLoginCookies: hasLogin,
                                                         directoryName: directoryName, lastActivity: lastActivity(of: url)))
                        } catch where isMissing(error) { continue }
                        catch where browser.isDiscovered { continue }
                        catch { result.issues.append(issue(for: browser, root: root, error: error)) }
                    }
                }
            } catch where isMissing(error) { continue }
            catch where browser.isDiscovered { continue }
            catch { result.issues.append(issue(for: browser, root: root, error: error)) }
        }
        return result
    }

    public static func readActiveSession(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                         browsers: [BrowserSessionDefinition] = BrowserSessionDefinition.supported,
                                         customRoots: [String: URL] = [:], preferredBrowserID: String? = nil,
                                         password: ((BrowserSessionDefinition) throws -> Data)? = nil) throws -> ChromeXSession {
        let selection = BrowserSessionSelection(preferredBrowserID)
        let selected: [BrowserSessionDefinition]
        if let browserID = selection.browserID {
            guard let browser = browsers.first(where: { $0.id == browserID }) else {
                throw BrowserSessionError.unavailable("所选浏览器暂不受支持，请在设置中重新选择来源。")
            }
            selected = [browser]
        } else { selected = browsers }
        var probe = probe(home: home, browsers: selected, customRoots: customRoots)
        probe.selection = selection
        var failures: [String] = []
        var passwords: [String: Data] = [:]
        if probe.selectedProfiles.isEmpty, selection.profileDirectory != nil,
           probe.loggedInProfiles.contains(where: { $0.browser.id == selection.browserID }) {
            throw BrowserSessionError.unavailable("所选的浏览器配置已没有有效的 X 登录，请在设置的“使用浏览器”中重新选择。")
        }
        for profile in probe.selectedProfiles {
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
            var result: [(URL, String)] = []
            var seen = Set<String>()
            // profiles.ini can point at profiles outside Profiles/.
            for (directory, name) in firefoxIniProfiles(root: root) where seen.insert(directory.standardizedFileURL.path).inserted {
                result.append((directory, name))
            }
            let profilesRoot = root.appending(path: "Profiles")
            let contents: [URL]
            do {
                contents = try FileManager.default.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            } catch where isMissing(error) && !result.isEmpty {
                contents = []
            }
            for directory in contents.filter({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where seen.insert(directory.standardizedFileURL.path).inserted {
                result.append((directory, directory.lastPathComponent))
            }
            return result
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

    static func firefoxIniProfiles(root: URL) -> [(URL, String)] {
        guard let text = try? String(contentsOf: root.appending(path: "profiles.ini"), encoding: .utf8) else { return [] }
        var result: [(URL, String)] = []
        var name: String?, path: String?, relative = true
        func flush() {
            defer { name = nil; path = nil; relative = true }
            guard let path, !path.isEmpty else { return }
            let url = relative ? root.appending(path: path) : URL(fileURLWithPath: path)
            // A relative path must stay inside the browser root.
            if relative, !url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") { return }
            result.append((url, name ?? url.lastPathComponent))
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { flush(); continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Name": name = parts[1]
            case "Path": path = parts[1]
            case "IsRelative": relative = parts[1] != "0"
            default: break
            }
        }
        flush()
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

    /// Looks the key up by service name only: the account name differs
    /// between browser versions and channels.
    static func safeStoragePassword(_ browser: BrowserSessionDefinition) throws -> Data {
        var lastError: Error?
        for service in browser.keychainServices {
            do {
                if let value = try KeychainStore.read(account: nil, service: service), !value.isEmpty {
                    return Data(value.utf8)
                }
            } catch { lastError = error }
        }
        if let lastError { throw BrowserSessionError.unavailable("未能读取 \(browser.name) 的钥匙串密钥：\(lastError.localizedDescription)") }
        throw BrowserSessionError.unavailable("未能读取 \(browser.name) 的钥匙串密钥（\(browser.keychainServices.joined(separator: " / "))）")
    }

    /// Reads a private copy of the cookie database. A running Chromium
    /// browser keeps its cookie database under an exclusive SQLite lock, so
    /// opening the original fails with “database is locked” while it is open.
    static func withDatabase<T>(_ url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        let fileManager = FileManager.default
        // Fails like the original when macOS blocks access or the file is gone.
        _ = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let copyDirectory = fileManager.temporaryDirectory.appending(path: "markx-cookies-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: copyDirectory) }
        var openPath = url.path
        var flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        do {
            try fileManager.createDirectory(at: copyDirectory, withIntermediateDirectories: true)
            let copy = copyDirectory.appending(path: url.lastPathComponent)
            try fileManager.copyItem(at: url, to: copy)
            for suffix in ["-wal", "-journal"] where fileManager.fileExists(atPath: url.path + suffix) {
                try? fileManager.copyItem(atPath: url.path + suffix, toPath: copy.path + suffix)
            }
            openPath = copy.path
            // Read-write so SQLite can replay a copied WAL into the copy.
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        } catch {
            if isPermissionDenied(error) { throw error }
        }
        var db: OpaquePointer?
        let status = sqlite3_open_v2(openPath, &db, flags, nil)
        guard status == SQLITE_OK, let database = db else {
            if let db { sqlite3_close(db) }
            throw BrowserSessionError.unavailable("浏览器数据无法打开（\(status)），可能受到 macOS 访问权限限制")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_500)
        return try body(database)
    }

    static func lastActivity(of databaseURL: URL) -> Date? {
        ["", "-wal", "-journal"].compactMap { suffix in
            (try? FileManager.default.attributesOfItem(atPath: databaseURL.path + suffix))?[.modificationDate] as? Date
        }.max()
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
    static func issue(for browser: BrowserSessionDefinition, root: URL, error: Error) -> BrowserSessionIssue {
        BrowserSessionIssue(browserID: browser.id, browserName: browser.name, root: root,
                            detail: readableError(error), isPermissionDenied: isPermissionDenied(error))
    }
    static func isPermissionDenied(_ error: Error) -> Bool {
        let e = error as NSError
        return (e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError) || (e.domain == NSPOSIXErrorDomain && [1, 13].contains(e.code))
    }
    static func readableError(_ error: Error) -> String {
        let e = error as NSError
        if isPermissionDenied(error) { return "macOS 尚未允许读取此目录" }
        return error is BrowserSessionError ? error.localizedDescription : "读取配置失败（\(e.code)）"
    }
}
