import Foundation
import XCTest
@testable import XArticleArchiverCore

final class AppUpdateTests: XCTestCase {
    private let checksum = String(repeating: "a", count: 64)

    func testComparesVersionsNumericallyThenBuild() {
        let manifest = ReleaseManifest(version: "0.3.10", build: "160", sha256: checksum)
        XCTAssertTrue(AppUpdatePolicy.isNewer(manifest, thanVersion: "0.3.9", build: "200"))
        XCTAssertFalse(AppUpdatePolicy.isNewer(manifest, thanVersion: "0.4", build: "1"))
        XCTAssertFalse(AppUpdatePolicy.isNewer(manifest, thanVersion: "0.3.10", build: "160"))
        XCTAssertTrue(AppUpdatePolicy.isNewer(manifest, thanVersion: "0.3.10.0", build: "159"))
    }

    func testDecodesLegacyReceiptWithDefaultDownloadURL() throws {
        let data = Data(#"{"version": "0.3.65", "build": "154", "sha256": "\#(checksum)"}"#.utf8)
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
        XCTAssertNil(manifest.notes)
        XCTAssertEqual(manifest.downloadURL.absoluteString, "https://download.markx.defou.ai/0.3.65/MarkX-0.3.65.dmg")
        XCTAssertNoThrow(try AppUpdatePolicy.validate(manifest))
    }

    func testDecodesReceiptWithNotesAndRejectsUntrustedHosts() throws {
        let data = Data(#"""
        {"version": "0.3.66", "build": "155", "sha256": "\#(checksum)",
         "url": "https://example.com/MarkX.dmg", "notes": ["新增自动更新"]}
        """#.utf8)
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
        XCTAssertEqual(manifest.notes, ["新增自动更新"])
        XCTAssertThrowsError(try AppUpdatePolicy.validate(manifest)) {
            XCTAssertEqual($0 as? AppUpdateError, .untrustedDownload(URL(string: "https://example.com/MarkX.dmg")!))
        }
        XCTAssertNoThrow(try AppUpdatePolicy.validate(manifest, allowAnyHost: true))
    }

    func testRejectsMalformedChecksum() {
        let manifest = ReleaseManifest(version: "1.0", build: "1", sha256: "abc")
        XCTAssertThrowsError(try AppUpdatePolicy.validate(manifest))
    }

    func testStagesSignedAppFromDiskImageAndRejectsWrongChecksum() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("markx-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("src")
        let app = source.appendingPathComponent("MarkX.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: app.appendingPathComponent("MacOS/MarkX"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "ai.defou.update-test", "CFBundleExecutable": "MarkX",
            "CFBundleShortVersionString": "9.9.9", "CFBundleVersion": "999", "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertEqual(shell("/usr/bin/codesign", "--force", "--deep", "--sign", "-",
                             source.appendingPathComponent("MarkX.app").path), 0)
        let dmg = work.appendingPathComponent("MarkX.dmg")
        // macOS 27 deprecates `hdiutil create`, whose -srcfolder images can come
        // out unreadable there; prefer `diskutil image` when it exists.
        if shell("/usr/sbin/diskutil", "image", "create", "from", "--format", "UDZO",
                 "--volumeName", "MarkXTest", source.path, dmg.path) != 0 {
            XCTAssertEqual(shell("/usr/bin/hdiutil", "create", "-quiet", "-fs", "HFS+", "-srcfolder", source.path,
                                 "-format", "UDZO", dmg.path), 0)
        }
        let sum = try AppUpdateInstaller.sha256(of: dmg)

        let staging = work.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AppUpdateInstaller.stageApp(
            fromDiskImage: dmg, expectedSHA256: checksum, expectedBundleID: "ai.defou.update-test",
            expectedVersion: "9.9.9", in: staging)) { XCTAssertEqual($0 as? AppUpdateError, .checksumMismatch) }
        XCTAssertThrowsError(try AppUpdateInstaller.stageApp(
            fromDiskImage: dmg, expectedSHA256: sum, expectedBundleID: "ai.defou.other",
            expectedVersion: "9.9.9", in: staging))

        let staged = try AppUpdateInstaller.stageApp(
            fromDiskImage: dmg, expectedSHA256: sum.uppercased(), expectedBundleID: "ai.defou.update-test",
            expectedVersion: "9.9.9", in: staging)
        XCTAssertEqual(Bundle(url: staged)?.infoDictionary?["CFBundleVersion"] as? String, "999")
    }

    @discardableResult
    private func shell(_ tool: String, _ arguments: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
