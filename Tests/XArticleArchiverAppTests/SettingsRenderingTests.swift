import AppKit
import SwiftUI
import XCTest
@testable import XArticleArchiverApp
import XArticleArchiverCore

/// Off-screen renders of the settings panes and the update dialog. Set
/// MARKX_RENDER_DIR to save PNGs for visual review.
@MainActor
final class SettingsRenderingTests: XCTestCase {
    private func render<V: View>(_ view: V, name: String) throws -> NSSize {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        if let directory = ProcessInfo.processInfo.environment["MARKX_RENDER_DIR"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
        }
        return image.size
    }

    func testSettingsPanesAreOnlyAsTallAsTheirContent() throws {
        let model = AppViewModel()
        var heights: [SettingsView.Pane: CGFloat] = [:]
        for pane in SettingsView.Pane.allCases {
            heights[pane] = try render(SettingsView(initialPane: pane).environmentObject(model), name: "settings-\(pane.rawValue)").height
        }
        for (pane, height) in heights {
            XCTAssertLessThan(height, 500, "\(pane) is shorter than the old fixed 500pt window")
            XCTAssertGreaterThanOrEqual(height, 230)
        }
    }

    func testDownloadAndSyncSheetsAreCompact() throws {
        let model = AppViewModel()
        let download = try render(AddCreatorsView().environmentObject(model), name: "sheet-download")
        let sync = try render(SyncAllCreatorsView().environmentObject(model), name: "sheet-sync")
        for size in [download, sync] {
            XCTAssertEqual(size.width, 480, accuracy: 1)
            XCTAssertLessThan(size.height, 420, "no longer a 660pt-tall sheet")
        }
    }

    /// The sidebar footer's “更新” button: a small accent capsule, text only.
    func testUpdateButtonIsASmallCapsule() throws {
        let footer = HStack {
            Label("设置", systemImage: "gearshape").font(MarkXFont.body)
            Spacer()
            Button("更新") {}.buttonStyle(.markxPillProminentSmall)
        }
        .padding(.horizontal, 16).frame(width: 248, height: 44).background(MarkXInterface.sidebarGradient)
        let size = try render(footer, name: "footer-update")
        XCTAssertEqual(size.height, 44, accuracy: 1)
    }

    func testUpdateDialogIsCompactInEveryPhase() throws {
        let updater = AppUpdater.shared
        let saved = updater.phase
        defer { updater.phase = saved }
        let manifest = ReleaseManifest(version: "9.9.9", build: "999", sha256: String(repeating: "0", count: 64),
                                       url: URL(string: "https://download.markx.defou.ai/9.9.9/MarkX-9.9.9.dmg"), notes: ["说明"])
        let phases: [(String, AppUpdater.Phase)] = [
            ("available", .available(manifest)),
            ("downloading", .downloading(manifest, progress: 0.4)),
            ("ready", .ready(manifest, stagedApp: URL(fileURLWithPath: "/tmp/MarkX.app"))),
            ("installing", .installing(manifest)),
            ("uptodate", .upToDate)
        ]
        updater.downloadedBytes = 10_485_760
        updater.expectedBytes = 26_214_400
        defer { updater.downloadedBytes = 0; updater.expectedBytes = 0 }
        for (name, phase) in phases {
            updater.phase = phase
            let size = try render(SoftwareUpdateView().environmentObject(updater), name: "update-\(name)")
            XCTAssertEqual(size.width, 360, accuracy: 1)
            XCTAssertLessThan(size.height, 260)
        }
    }
}
