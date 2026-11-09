import Foundation
import SQLite3
import XCTest
@testable import XArticleArchiverCore

final class BrowserXSessionReaderTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "markx-browser-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testFindsDefaultWithoutLocalStateAndFiltersOtherWebsites() throws {
        let root = directory.appending(path: "Chrome")
        let db = try chromium(root.appending(path: "Default/Cookies"))
        try login(db)
        try execute(db, "INSERT INTO cookies(host_key,name,value) VALUES('.google.com','auth_token','unrelated-test-value'),('.x.com','unrelated_name','not-a-session-cookie')")
        let probe = BrowserXSessionReader.probe(browsers: [.chrome], customRoots: ["chrome": root])
        XCTAssertEqual(probe.loggedInProfiles.count, 1)
        let session = try read(root)
        XCTAssertEqual(session.browserName, "Chrome")
        XCTAssertEqual(Set(session.cookies.map(\.name)), Set(["auth_token", "ct0"]))
        XCTAssertTrue(session.cookies.allSatisfy { $0.domain == ".x.com" })
    }

    func testSearchesOtherProfilesWhenLastUsedProfileIsLoggedOut() throws {
        let root = directory.appending(path: "Chrome")
        _ = try chromium(root.appending(path: "Default/Cookies"))
        try login(chromium(root.appending(path: "Profile 2/Network/Cookies")))
        try state(root, ["last_used": "Default", "info_cache": ["Default": ["name": "Personal"], "Profile 2": ["name": "Work"]]])
        let session = try read(root)
        XCTAssertEqual(session.profileName, "Work")
    }

    func testChecksBothCookieDatabaseLocations() throws {
        let root = directory.appending(path: "Chrome")
        _ = try chromium(root.appending(path: "Default/Network/Cookies"))
        try login(chromium(root.appending(path: "Default/Cookies")))
        XCTAssertEqual(try read(root).cookies.count, 2)
    }

    func testExpiredAndPartitionedAuthRecordsAreNotLoginEvidence() throws {
        let root = directory.appending(path: "Chrome")
        let db = try chromium(root.appending(path: "Default/Cookies"))
        try execute(db, "INSERT INTO cookies(host_key,name,value,expires_utc) VALUES('.x.com','auth_token','expired',1),('.x.com','ct0','csrf',0)")
        XCTAssertFalse(BrowserXSessionReader.probe(browsers: [.chrome], customRoots: ["chrome": root]).profiles[0].hasLoginCookies)
        try execute(db, "INSERT INTO cookies(host_key,name,value,top_frame_site_key) VALUES('.x.com','auth_token','partitioned','https://another.example')")
        XCTAssertFalse(BrowserXSessionReader.probe(browsers: [.chrome], customRoots: ["chrome": root]).profiles[0].hasLoginCookies)
        try execute(db, "INSERT INTO cookies(host_key,name,value) VALUES('.x.com','auth_token','regular')")
        let session = try read(root)
        XCTAssertEqual(session.cookies.first(where: { $0.name == "auth_token" })?.value, "regular")
    }

    func testOptionalCookieEncryptionFailureDoesNotInvalidateGoodSession() throws {
        let root = directory.appending(path: "Chrome")
        let db = try chromium(root.appending(path: "Default/Cookies"))
        try login(db)
        try execute(db, "INSERT INTO cookies(host_key,name,encrypted_value) VALUES('.x.com','guest_id',X'76323000010203')")
        XCTAssertEqual(try read(root).cookies.count, 2)
    }

    func testExplicitBrowserChoiceKeepsAccountsSeparate() throws {
        let chrome = directory.appending(path: "Chrome")
        let edge = directory.appending(path: "Edge")
        try login(chromium(chrome.appending(path: "Default/Cookies")), auth: "chrome-test-account")
        try login(chromium(edge.appending(path: "Default/Cookies")), auth: "edge-test-account")
        let definitions = BrowserSessionDefinition.supported.filter { ["chrome", "edge"].contains($0.id) }
        let session = try BrowserXSessionReader.readActiveSession(browsers: definitions, customRoots: ["chrome": chrome, "edge": edge], preferredBrowserID: "edge", password: { _ in Data() })
        XCTAssertEqual(session.browserName, "Edge")
        XCTAssertEqual(session.cookies.first(where: { $0.name == "auth_token" })?.value, "edge-test-account")
    }

    func testCorruptDatabaseReportsReadFailureInsteadOfRequestingLogin() throws {
        let root = directory.appending(path: "Chrome")
        let db = root.appending(path: "Default/Cookies")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: db)
        let probe = BrowserXSessionReader.probe(browsers: [.chrome], customRoots: ["chrome": root])
        XCTAssertFalse(probe.issues.isEmpty)
        XCTAssertThrowsError(try read(root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("无法读取"))
            XCTAssertFalse(error.localizedDescription.contains("请先登录"))
        }
    }

    func testUnknownExplicitBrowserDoesNotImportADifferentAccount() throws {
        let root = directory.appending(path: "Chrome")
        try login(chromium(root.appending(path: "Default/Cookies")))
        XCTAssertThrowsError(try BrowserXSessionReader.readActiveSession(browsers: [.chrome], customRoots: ["chrome": root], preferredBrowserID: "unknown-browser", password: { _ in Data() })) { error in
            XCTAssertTrue(error.localizedDescription.contains("重新选择来源"))
        }
    }

    func testProfileNamesCannotEscapeBrowserRoot() throws {
        let root = directory.appending(path: "Chrome")
        _ = try chromium(root.appending(path: "Default/Cookies"))
        try login(chromium(directory.appending(path: "Outside/Cookies")))
        try state(root, ["last_used": "../Outside", "info_cache": ["../Outside": ["name": "Outside"]]])
        let probe = BrowserXSessionReader.probe(browsers: [.chrome], customRoots: ["chrome": root])
        XCTAssertTrue(probe.loggedInProfiles.isEmpty)
        XCTAssertTrue(probe.profiles.allSatisfy { $0.databaseURL.path.hasPrefix(root.path + "/") })
    }

    func testReadsUncheckpointedCommittedWALCookies() throws {
        let root = directory.appending(path: "Chrome")
        let url = try chromium(root.appending(path: "Default/Cookies"))
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO cookies(host_key,name,value) VALUES('.x.com','auth_token','wal-auth'),('.x.com','ct0','wal-csrf')", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try read(root).cookies.count, 2)
    }

    func testFirefoxContainersAreNotCombinedIntoOneSession() throws {
        let root = directory.appending(path: "Firefox")
        let db = root.appending(path: "Profiles/example.default/cookies.sqlite")
        try FileManager.default.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute(db, "CREATE TABLE moz_cookies(host TEXT,name TEXT,value TEXT,path TEXT DEFAULT '/',expiry INTEGER DEFAULT 0,isSecure INTEGER DEFAULT 1,isHttpOnly INTEGER DEFAULT 1,originAttributes TEXT DEFAULT ''); INSERT INTO moz_cookies(host,name,value,originAttributes) VALUES('.x.com','auth_token','a','^userContextId=1'),('.x.com','ct0','b','^userContextId=2')")
        let firefox = BrowserSessionDefinition.supported.first(where: { $0.id == "firefox" })!
        XCTAssertTrue(BrowserXSessionReader.probe(browsers: [firefox], customRoots: ["firefox": root]).loggedInProfiles.isEmpty)
        try execute(db, "INSERT INTO moz_cookies(host,name,value,originAttributes) VALUES('.x.com','ct0','a-csrf','^userContextId=1'),('.other.example','auth_token','unrelated','^userContextId=1')")
        let session = try BrowserXSessionReader.readActiveSession(browsers: [firefox], customRoots: ["firefox": root])
        XCTAssertEqual(Set(session.cookies.map(\.value)), Set(["a", "a-csrf"]))
        XCTAssertEqual(session.browserName, "Firefox")
    }

    func testFallsBackToAnotherBrowserAfterKeychainFailure() throws {
        let chrome = directory.appending(path: "Chrome")
        let firefoxRoot = directory.appending(path: "Firefox")
        try login(chromium(chrome.appending(path: "Default/Cookies")))
        let ff = firefoxRoot.appending(path: "cookies.sqlite")
        try FileManager.default.createDirectory(at: firefoxRoot, withIntermediateDirectories: true)
        try execute(ff, "CREATE TABLE moz_cookies(host TEXT,name TEXT,value TEXT,path TEXT DEFAULT '/',expiry INTEGER DEFAULT 0,isSecure INTEGER DEFAULT 1,isHttpOnly INTEGER DEFAULT 1); INSERT INTO moz_cookies(host,name,value) VALUES('.x.com','auth_token','ff-test'),('.x.com','ct0','csrf-test')")
        let definitions = BrowserSessionDefinition.supported.filter { ["chrome", "firefox"].contains($0.id) }
        let session = try BrowserXSessionReader.readActiveSession(browsers: definitions, customRoots: ["chrome": chrome, "firefox": firefoxRoot], password: { _ in throw BrowserSessionError.unavailable("keychain denied in fixture") })
        XCTAssertEqual(session.browserName, "Firefox")
    }

    private func read(_ root: URL) throws -> ChromeXSession {
        try BrowserXSessionReader.readActiveSession(browsers: [.chrome], customRoots: ["chrome": root], password: { _ in Data() })
    }
    @discardableResult
    private func chromium(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute(url, "CREATE TABLE meta(key TEXT,value TEXT); INSERT INTO meta VALUES('version','24'); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT DEFAULT '',encrypted_value BLOB DEFAULT X'',path TEXT DEFAULT '/',expires_utc INTEGER DEFAULT 0,is_secure INTEGER DEFAULT 1,is_httponly INTEGER DEFAULT 1,samesite INTEGER DEFAULT 1,top_frame_site_key TEXT DEFAULT '')")
        return url
    }
    private func login(_ db: URL, auth: String = "test-auth") throws {
        try execute(db, "INSERT INTO cookies(host_key,name,value) VALUES('.x.com','auth_token','\(auth)'),('.x.com','ct0','test-csrf')")
    }
    private func state(_ root: URL, _ profile: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: ["profile": profile]).write(to: root.appending(path: "Local State"))
    }
    private func execute(_ path: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { throw BrowserSessionError.unavailable("fixture database failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw BrowserSessionError.unavailable("fixture SQL failed: \(String(cString: sqlite3_errmsg(db)))") }
    }
}
