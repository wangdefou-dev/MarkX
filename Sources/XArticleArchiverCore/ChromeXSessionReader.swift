import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

public enum ChromeXSessionError: LocalizedError, Sendable {
    case chromeProfileNotFound
    case cookieDatabaseNotFound
    case cookieDatabase(String)
    case safeStorageUnavailable(OSStatus)
    case decryptionFailed
    case invalidCookie
    case noAuthenticatedXSession

    public var errorDescription: String? {
        switch self {
        case .chromeProfileNotFound:
            "没有找到本机 Chrome 配置"
        case .cookieDatabaseNotFound:
            "没有找到 Chrome Cookie 数据库"
        case .cookieDatabase(let detail):
            "无法读取浏览器的 X 登录状态：\(detail)"
        case .safeStorageUnavailable(let status):
            if status == errSecUserCanceled {
                "已取消访问 Chrome 安全存储"
            } else {
                "无法访问 Chrome Safe Storage（\(status)）"
            }
        case .decryptionFailed:
            "Chrome 的 X 登录状态解密失败"
        case .invalidCookie:
            "Chrome 返回了无法导入的 X Cookie"
        case .noAuthenticatedXSession:
            "当前配置没有可导入的 X 会话，请检查设置中的浏览器和配置来源"
        }
    }
}

public struct ChromeXSession: Sendable {
    public var profileName: String
    public var cookies: [HTTPCookie]
    public var browserName: String
    public var browserBundleIdentifier: String
    public var sourceDescription: String { "\(browserName)「\(profileName)」" }

    public init(profileName: String, cookies: [HTTPCookie], browserName: String = "Chrome", browserBundleIdentifier: String = "com.google.Chrome") {
        self.profileName = profileName
        self.cookies = cookies
        self.browserName = browserName
        self.browserBundleIdentifier = browserBundleIdentifier
    }
}

/// Chromium cookie decoder retained behind the multi-browser session reader.
/// Reads only X/Twitter cookies from one chosen profile. Values are decrypted in memory and are never logged or persisted by
/// this component. Google and every unrelated site are excluded at the SQL
/// query boundary.
public enum ChromeXSessionReader {
    private static let allowedHosts = [".x.com", "x.com", ".twitter.com", "twitter.com"]
    private static let allowedCookieNames: Set<String> = [
        "auth_token", "ct0", "twid", "kdt", "cf_clearance", "__cf_bm",
        "guest_id", "guest_id_ads", "guest_id_marketing", "personalization_id",
        "lang", "_twitter_sess"
    ]
    private static let chromiumEpochOffset: TimeInterval = 11_644_473_600

    public static func hasLocalChromeProfile(
        chromeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)
    ) -> Bool {
        !BrowserXSessionReader.probe(browsers: [.chrome], customRoots: ["chrome": chromeRoot]).profiles.isEmpty
    }

    public static func readActiveSession(
        chromeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)
    ) throws -> ChromeXSession {
        try BrowserXSessionReader.readActiveSession(browsers: [.chrome], customRoots: ["chrome": chromeRoot])
    }

    static func readSession(
        databaseURL: URL,
        profileName: String,
        safeStoragePassword: Data
    ) throws -> ChromeXSession {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let database { sqlite3_close(database) }
            throw ChromeXSessionError.cookieDatabase(detail)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_500)

        let databaseVersion = try readDatabaseVersion(database)
        let placeholders = allowedHosts.map { _ in "?" }.joined(separator: ",")
        let names = allowedCookieNames.sorted()
        let namePlaceholders = names.map { _ in "?" }.joined(separator: ",")
        let partitionClause = BrowserXSessionReader.tableColumns(database, table: "cookies").contains("top_frame_site_key") ? " AND top_frame_site_key = ''" : ""
        let sql = """
        SELECT host_key, name, value, encrypted_value, path, expires_utc,
               is_secure, is_httponly, samesite
        FROM cookies
        WHERE host_key IN (\(placeholders)) AND name IN (\(namePlaceholders))\(partitionClause);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ChromeXSessionError.cookieDatabase(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, host) in allowedHosts.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), host, -1, transient)
        }
        for (offset, name) in names.enumerated() {
            sqlite3_bind_text(statement, Int32(allowedHosts.count + offset + 1), name, -1, transient)
        }

        var cookies: [HTTPCookie] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            guard let host = text(statement, 0),
                  let name = text(statement, 1),
                  let path = text(statement, 4) else { continue }
            let chromeExpiry = sqlite3_column_int64(statement, 5)
            if chromeExpiry > 0, TimeInterval(chromeExpiry) / 1_000_000 - chromiumEpochOffset <= Date().timeIntervalSince1970 { continue }
            let clearValue = text(statement, 2) ?? ""
            let value: String
            if !clearValue.isEmpty {
                value = clearValue
            } else {
                let encrypted = data(statement, 3)
                do { value = try decryptCookieValue(
                    encrypted,
                    host: host,
                    password: safeStoragePassword,
                    databaseVersion: databaseVersion
                ) } catch {
                    if name == "auth_token" || name == "ct0" { throw error }
                    continue
                }
            }
            guard !value.isEmpty else { continue }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: host,
                .path: path,
                .name: name,
                .value: value,
                .version: 0
            ]
            if sqlite3_column_int(statement, 6) != 0 { properties[.secure] = "TRUE" }
            if sqlite3_column_int(statement, 7) != 0 {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            switch sqlite3_column_int(statement, 8) {
            case 0: properties[HTTPCookiePropertyKey("SameSite")] = "None"
            case 1: properties[HTTPCookiePropertyKey("SameSite")] = "Lax"
            case 2: properties[HTTPCookiePropertyKey("SameSite")] = "Strict"
            default: break
            }
            if chromeExpiry > 0 {
                let unixSeconds = TimeInterval(chromeExpiry) / 1_000_000 - chromiumEpochOffset
                properties[.expires] = Date(timeIntervalSince1970: unixSeconds)
            }
            guard let cookie = HTTPCookie(properties: properties) else {
                throw ChromeXSessionError.invalidCookie
            }
            cookies.append(cookie)
        }
        guard step == SQLITE_DONE else { throw ChromeXSessionError.cookieDatabase(String(cString: sqlite3_errmsg(database))) }

        guard cookies.contains(where: { $0.name == "auth_token" && $0.domain.contains("x.com") }) else {
            throw ChromeXSessionError.noAuthenticatedXSession
        }
        return ChromeXSession(profileName: profileName, cookies: cookies)
    }

    static func decryptCookieValue(
        _ encrypted: Data,
        host: String,
        password: Data,
        databaseVersion: Int
    ) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) || encrypted.starts(with: Data("v11".utf8)) else {
            throw ChromeXSessionError.decryptionFailed
        }
        let ciphertext = Data(encrypted.dropFirst(3))
        let salt = Data("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derivationStatus = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress,
                    password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    &key,
                    key.count
                )
            }
        }
        guard derivationStatus == kCCSuccess else { throw ChromeXSessionError.decryptionFailed }

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var outputLength = 0
        let cryptStatus = ciphertext.withUnsafeBytes { cipherBytes in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                key,
                key.count,
                iv,
                cipherBytes.baseAddress,
                ciphertext.count,
                &output,
                output.count,
                &outputLength
            )
        }
        guard cryptStatus == kCCSuccess else { throw ChromeXSessionError.decryptionFailed }
        var plaintext = Data(output.prefix(outputLength))

        // Cookie DB schema v24+ prefixes each decrypted value with SHA-256 of
        // host_key. Validate and remove it before constructing HTTPCookie.
        if databaseVersion >= 24 {
            let hostDigest = Data(SHA256.hash(data: Data(host.utf8)))
            guard plaintext.starts(with: hostDigest) else {
                throw ChromeXSessionError.decryptionFailed
            }
            plaintext.removeFirst(hostDigest.count)
        }
        guard let value = String(data: plaintext, encoding: .utf8) else {
            throw ChromeXSessionError.decryptionFailed
        }
        return value
    }

    private static func readDatabaseVersion(_ database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = 'version';", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ChromeXSessionError.cookieDatabase(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = text(statement, 0),
              let version = Int(raw) else { return 0 }
        return version
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func data(_ statement: OpaquePointer, _ index: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: pointer, count: count)
    }
}
