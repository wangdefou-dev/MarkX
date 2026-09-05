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
            "无法读取 Chrome 的 X 登录状态：\(detail)"
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
            "Chrome 当前没有可用的 X 登录状态；请先在 Chrome 打开 x.com 并确认已登录"
        }
    }
}

public struct ChromeXSession: Sendable {
    public var profileName: String
    public var cookies: [HTTPCookie]

    public init(profileName: String, cookies: [HTTPCookie]) {
        self.profileName = profileName
        self.cookies = cookies
    }
}

/// Reads only X/Twitter session cookies from the currently active local Chrome
/// profile. Values are decrypted in memory and are never logged or persisted by
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
        guard let profile = try? activeProfile(at: chromeRoot) else { return false }
        return FileManager.default.fileExists(atPath: cookieDatabaseURL(profileURL: profile.url).path)
    }

    public static func readActiveSession(
        chromeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)
    ) throws -> ChromeXSession {
        let profile = try activeProfile(at: chromeRoot)
        let databaseURL = cookieDatabaseURL(profileURL: profile.url)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ChromeXSessionError.cookieDatabaseNotFound
        }
        let password = try chromeSafeStoragePassword()
        return try readSession(
            databaseURL: databaseURL,
            profileName: profile.name,
            safeStoragePassword: password
        )
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

        let databaseVersion = try readDatabaseVersion(database)
        let placeholders = allowedHosts.map { _ in "?" }.joined(separator: ",")
        let names = allowedCookieNames.sorted()
        let namePlaceholders = names.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT host_key, name, value, encrypted_value, path, expires_utc,
               is_secure, is_httponly, samesite
        FROM cookies
        WHERE host_key IN (\(placeholders)) AND name IN (\(namePlaceholders));
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
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let host = text(statement, 0),
                  let name = text(statement, 1),
                  let path = text(statement, 4) else { continue }
            let clearValue = text(statement, 2) ?? ""
            let value: String
            if !clearValue.isEmpty {
                value = clearValue
            } else {
                let encrypted = data(statement, 3)
                value = try decryptCookieValue(
                    encrypted,
                    host: host,
                    password: safeStoragePassword,
                    databaseVersion: databaseVersion
                )
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
            let chromeExpiry = sqlite3_column_int64(statement, 5)
            if chromeExpiry > 0 {
                let unixSeconds = TimeInterval(chromeExpiry) / 1_000_000 - chromiumEpochOffset
                properties[.expires] = Date(timeIntervalSince1970: unixSeconds)
            }
            guard let cookie = HTTPCookie(properties: properties) else {
                throw ChromeXSessionError.invalidCookie
            }
            cookies.append(cookie)
        }

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

    private static func activeProfile(at root: URL) throws -> (url: URL, name: String) {
        let localStateURL = root.appending(path: "Local State")
        guard let data = try? Data(contentsOf: localStateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any] else {
            throw ChromeXSessionError.chromeProfileNotFound
        }
        let directoryName = (profile["last_used"] as? String).flatMap(safeProfileDirectory) ?? "Default"
        let profileURL = root.appending(path: directoryName, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw ChromeXSessionError.chromeProfileNotFound
        }
        let profileName: String
        if let infoCache = profile["info_cache"] as? [String: Any],
           let info = infoCache[directoryName] as? [String: Any],
           let name = info["name"] as? String,
           !name.isEmpty {
            profileName = name
        } else {
            profileName = directoryName
        }
        return (profileURL, profileName)
    }

    private static func safeProfileDirectory(_ value: String) -> String? {
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              value != ".",
              value != ".." else { return nil }
        return value
    }

    private static func cookieDatabaseURL(profileURL: URL) -> URL {
        let current = profileURL.appending(path: "Cookies")
        if FileManager.default.fileExists(atPath: current.path) { return current }
        return profileURL.appending(path: "Network/Cookies")
    }

    private static func chromeSafeStoragePassword() throws -> Data {
        do {
            guard let password = try KeychainStore.read(
                account: "Chrome",
                service: "Chrome Safe Storage"
            ), !password.isEmpty else {
                throw ChromeXSessionError.safeStorageUnavailable(errSecItemNotFound)
            }
            return Data(password.utf8)
        } catch let error as ChromeXSessionError {
            throw error
        } catch {
            throw ChromeXSessionError.safeStorageUnavailable(errSecAuthFailed)
        }
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
