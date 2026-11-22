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
    /// Bytes received and expected for the update download (0 when unknown).
    @Published internal(set) var downloadedBytes: Int64 = 0
    @Published internal(set) var expectedBytes: Int64 = 0
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
        downloadedBytes = 0
        expectedBytes = 0
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MarkX-Update-\(manifest.version)-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let dmg = directory.appendingPathComponent("MarkX-\(manifest.version).dmg")
                try await downloadFile(from: manifest.downloadURL, to: dmg) { [weak self] written, expected in
                    guard let self, case .downloading = self.phase else { return }
                    self.downloadedBytes = written
                    self.expectedBytes = expected
                    let fraction = expected > 0 ? min(1, Double(written) / Double(expected)) : 0
                    self.phase = .downloading(manifest, progress: fraction)
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

    /// A session-delegate download task: the async `download(from:delegate:)`
    /// API never reports `didWriteData`, which left the bar stuck at 0.
    private func downloadFile(from url: URL, to destination: URL,
                              progress: @escaping @MainActor (Int64, Int64) -> Void) async throws {
        let delegate = UpdateDownloadDelegate(destination: destination) { written, expected in
            Task { @MainActor in progress(written, expected) }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.setContinuation(continuation)
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
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

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finishError: Error?
    private var lastReported: Int64 = -1

    init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = max(totalBytesExpectedToWrite, 0)
        // About every 0.5% (or 256 KB when the size is unknown).
        let step = expected > 0 ? max(expected / 200, 1) : 256 * 1024
        guard totalBytesWritten - lastReported >= step || (expected > 0 && totalBytesWritten >= expected) else { return }
        lastReported = totalBytesWritten
        onProgress(totalBytesWritten, expected)
    }

    // The file at `location` is deleted when this returns, so move it now.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            finishError = AppUpdateError.diskImage("下载失败（HTTP \(status)）")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finishError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error {
            let cancelled = (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
            continuation?.resume(throwing: cancelled ? CancellationError() : error)
        } else if let finishError {
            continuation?.resume(throwing: finishError)
        } else {
            let expected = max(task.countOfBytesExpectedToReceive, task.countOfBytesReceived)
            onProgress(task.countOfBytesReceived, expected)
            continuation?.resume()
        }
    }
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
        case .downloading(let m, _): "正在下载 \(m.version)…"
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
            VStack(spacing: MarkXSpace.s) {
                UpdateProgressBar(fraction: updater.expectedBytes > 0 ? fraction : nil)
                    .frame(width: 240)
                Text(downloadLine(fraction: fraction))
                    .font(MarkXFont.detail)
                    .monospacedDigit()
                    .foregroundStyle(MarkXInterface.text2)
            }
        default:
            EmptyView()
        }
    }

    private func downloadLine(fraction: Double) -> String {
        let received = ByteCountFormatter.string(fromByteCount: updater.downloadedBytes, countStyle: .file)
        guard updater.expectedBytes > 0 else { return "已下载 \(received)" }
        let total = ByteCountFormatter.string(fromByteCount: updater.expectedBytes, countStyle: .file)
        return "\(Int((fraction * 100).rounded(.down)))%  ·  \(received) / \(total)"
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
/// Capsule bar in the app's accent colour; `nil` shows a moving segment
/// while the size is unknown.
private struct UpdateProgressBar: View {
    var fraction: Double?
    @State private var phase = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(MarkXInterface.washStrong)
                if let fraction {
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(6, proxy.size.width * min(max(fraction, 0), 1)))
                        .animation(.easeOut(duration: 0.2), value: fraction)
                } else {
                    Capsule().fill(Color.accentColor)
                        .frame(width: proxy.size.width * 0.3)
                        .offset(x: phase ? proxy.size.width * 0.7 : 0)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
                        .onAppear { phase = true }
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("下载进度")
        .accessibilityValue(fraction.map { "\(Int($0 * 100))%" } ?? "正在下载")
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
