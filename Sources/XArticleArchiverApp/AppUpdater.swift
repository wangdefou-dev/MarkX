import AppKit
import SwiftUI
import XArticleArchiverCore

/// Checks the website's release receipt, downloads and verifies the DMG, and
/// replaces the running app in place.
@MainActor
final class AppUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseManifest)
        case downloading(ReleaseManifest, progress: Double)
        case ready(ReleaseManifest, stagedApp: URL)
        case installing(ReleaseManifest)
        case failed(String)
    }

    static let shared = AppUpdater()
    static let automaticChecksKey = "automaticallyChecksForUpdates"
    private static let skippedVersionKey = "skippedUpdateVersion"
    private static let lastCheckKey = "lastUpdateCheck"
    /// Frequent enough that a pushed release shows its “更新” button soon.
    private static let checkInterval: TimeInterval = 60 * 60

    @Published internal(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?
    /// Set by the app so installing never interrupts an archive task.
    var isBusy: () -> Bool = { false }

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    private let manifestURL: URL
    private let isManifestOverridden: Bool
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var window: NSWindow?

    /// A newer version is known: the main window shows its “更新” button.
    var hasUpdate: Bool {
        switch phase {
        case .available, .downloading, .ready, .installing: true
        default: false
        }
    }

    /// Updating only makes sense for a real app bundle (not `swift run`).
    var isSupported: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    private init() {
        let override = ProcessInfo.processInfo.environment["MARKX_UPDATE_MANIFEST_URL"].flatMap(URL.init(string:))
        manifestURL = override ?? AppUpdatePolicy.manifestURL
        isManifestOverridden = override != nil
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        UserDefaults.standard.register(defaults: [Self.automaticChecksKey: true])
    }

    // MARK: Scheduling

    func startAutomaticChecks() {
        guard isSupported, timer == nil else { return }
        #if DEBUG
        guard isManifestOverridden else { return }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.automaticCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.automaticCheck() }
        }
    }

    private func automaticCheck() {
        guard UserDefaults.standard.bool(forKey: Self.automaticChecksKey), !hasUpdate else { return }
        // A little slack so the hourly timer is never skipped by seconds.
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval - 5 * 60, !isManifestOverridden { return }
        check(userInitiated: false)
    }

    // MARK: Actions

    func check(userInitiated: Bool) {
        switch phase {
        case .checking, .downloading, .installing:
            if userInitiated { showWindow() }
            return
        case .ready:
            if userInitiated { showWindow() }
            return
        default: break
        }
        guard isSupported else {
            phase = .failed("开发版本不支持自动更新。")
            if userInitiated { showWindow() }
            return
        }
        phase = .checking
        if userInitiated { showWindow() }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let manifest = try await fetchManifest()
                lastChecked = Date()
                UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckKey)
                if AppUpdatePolicy.isNewer(manifest, thanVersion: currentVersion, build: currentBuild) {
                    phase = .available(manifest)
                    // Automatic checks only light up the “更新” button.
                    if userInitiated { showWindow() }
                } else {
                    phase = .upToDate
                }
            } catch is CancellationError {
                phase = .idle
            } catch {
                // A quiet background failure leaves no error state behind.
                phase = userInitiated ? .failed("无法检查更新：\(error.localizedDescription)") : .idle
            }
        }
    }

    func download() {
        guard case .available(let manifest) = phase else { return }
        phase = .downloading(manifest, progress: 0)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MarkX-Update-\(manifest.version)-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let dmg = directory.appendingPathComponent("MarkX-\(manifest.version).dmg")
                try await downloadFile(from: manifest.downloadURL, to: dmg) { [weak self] fraction in
                    self?.phase = .downloading(manifest, progress: fraction)
                }
                let bundleID = Bundle.main.bundleIdentifier ?? ""
                let staged = try await Task.detached(priority: .userInitiated) {
                    try AppUpdateInstaller.stageApp(
                        fromDiskImage: dmg, expectedSHA256: manifest.sha256,
                        expectedBundleID: bundleID, expectedVersion: manifest.version, in: directory
                    )
                }.value
                // Downloaded and verified; installing waits for the user.
                phase = .ready(manifest, stagedApp: staged)
                showWindow()
            } catch is CancellationError {
                phase = .available(manifest)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func installAndRelaunch() {
        guard case .ready(let manifest, let staged) = phase, !isBusy() else { return }
        phase = .installing(manifest)
        let installed = Bundle.main.bundleURL
        do {
            try AppUpdateInstaller.replace(installedApp: installed, with: staged)
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            try AppUpdateInstaller.relaunch(installed, afterProcessExits: ProcessInfo.processInfo.processIdentifier)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func skip() {
        if case .available(let manifest) = phase {
            UserDefaults.standard.set(manifest.version, forKey: Self.skippedVersionKey)
        }
        closeWindow()
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .downloading(let manifest, _) = phase { phase = .available(manifest) }
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(URL(string: "https://markx.defou.ai")!)
    }

    // MARK: Networking

    private func fetchManifest() async throws -> ReleaseManifest {
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("MarkX/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AppUpdateError.server(status) }
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
        try AppUpdatePolicy.validate(manifest, allowAnyHost: isManifestOverridden)
        return manifest
    }

    private func downloadFile(from url: URL, to destination: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let delegate = DownloadProgressDelegate { fraction in Task { @MainActor in progress(fraction) } }
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppUpdateError.diskImage("下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
    }

    // MARK: Window

    func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: SoftwareUpdateView().environmentObject(self))
            // The window follows the dialog's height as the phase changes.
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "软件更新"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 360, height: 200))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        window?.close()
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    private var reported = 0.0

    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard fraction - reported >= 0.01 || fraction >= 1 else { return }
        reported = fraction
        onProgress(fraction)
    }

    // The async download API moves the file itself.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// One short dialog: there is a new version, download it, it installs and
/// relaunches by itself.
struct SoftwareUpdateView: View {
    @EnvironmentObject private var updater: AppUpdater

    var body: some View {
        VStack(spacing: MarkXSpace.xl) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(spacing: MarkXSpace.s) {
                Text(title).font(MarkXFont.headline)
                if let detail {
                    Text(detail)
                        .font(MarkXFont.detail)
                        .foregroundStyle(MarkXInterface.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            progress
            HStack(spacing: MarkXSpace.m) { actions }
                .buttonStyle(.markxPill)
                .controlSize(.regular)
        }
        .padding(.horizontal, MarkXSpace.x4)
        .padding(.top, MarkXSpace.x5)
        .padding(.bottom, MarkXSpace.x3)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(MarkXInterface.canvas)
    }

    private var title: String {
        switch updater.phase {
        case .idle, .checking: "正在检查更新…"
        case .upToDate: "已是最新版本"
        case .available(let m): "有新版本 \(m.version)"
        case .downloading: "正在下载…"
        case .ready: "下载完成，安装并重启？"
        case .installing: "正在安装，即将重启…"
        case .failed: "更新未完成"
        }
    }

    private var detail: String? {
        switch updater.phase {
        case .failed(let message): message
        case .ready where updater.isBusy(): "下载任务结束后即可安装。"
        default: nil
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch updater.phase {
        case .checking, .idle, .installing:
            ProgressView().controlSize(.small)
        case .downloading(_, let fraction):
            ProgressView(value: fraction).frame(width: 220)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch updater.phase {
        case .available:
            Button("稍后") { updater.closeWindow() }.keyboardShortcut(.cancelAction)
            Button("下载更新") { updater.download() }
                .buttonStyle(.markxPillProminent).keyboardShortcut(.defaultAction)
        case .downloading:
            Button("取消") { updater.cancel() }.keyboardShortcut(.cancelAction)
        case .ready:
            Button("稍后") { updater.closeWindow() }.keyboardShortcut(.cancelAction)
            Button("安装并重启") { updater.installAndRelaunch() }
                .buttonStyle(.markxPillProminent).keyboardShortcut(.defaultAction)
                .disabled(updater.isBusy())
        case .installing, .checking, .idle:
            EmptyView()
        case .failed:
            Button("重试") { updater.check(userInitiated: true) }
                .buttonStyle(.markxPillProminent).keyboardShortcut(.defaultAction)
        case .upToDate:
            Button("好") { updater.closeWindow() }
                .buttonStyle(.markxPillProminent).keyboardShortcut(.defaultAction)
        }
    }
}
/// Settings group for the 通用 pane.
struct SoftwareUpdateSettingsSection: View {
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage(AppUpdater.automaticChecksKey) private var automaticChecks = true

    var body: some View {
        MarkXGroup(title: "软件更新") {
            MarkXRow(title: "自动检查更新", symbol: "arrow.triangle.2.circlepath") {
                Toggle("自动检查更新", isOn: $automaticChecks)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            MarkXRow(title: "当前版本 \(updater.currentVersion)（\(updater.currentBuild)）",
                     detail: updater.lastChecked.map { "上次检查：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未检查",
                     symbol: "shippingbox") {
                Button("立即检查") { updater.check(userInitiated: true) }
                    .buttonStyle(.markxCompact)
                    .disabled(!updater.isSupported)
            }
        }
    }
}
