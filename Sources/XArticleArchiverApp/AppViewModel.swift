import AppKit
import Foundation
import SwiftUI
import XArticleArchiverCore

private enum ArticleDeletionError: LocalizedError {
    case outsideArchiveRoot(String)

    var errorDescription: String? {
        switch self {
        case .outsideArchiveRoot(let path):
            "拒绝删除归档目录之外的文件：\(path)"
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    private enum ActiveArchiveOperation {
        case download
        case syncAll(creatorCount: Int, articleLimit: Int, resolvesTotalCount: Bool)
        case refreshCounts(creatorCount: Int)
    }

    enum ImageHostChoice: String, CaseIterable, Identifiable {
        case local
        case uPic
        case s3

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .local: "本地存储"
            case .uPic: "本地 + uPic"
            case .s3: "原生 S3 / R2"
            }
        }
    }

    enum SidebarSelection: Hashable {
        case all
        case today
        case pending
        case failed
        case creator(UUID)
    }

    enum ConnectionSetupTarget {
        case overview
        case imageHost
    }

    @Published var creators: [Creator] = []
    @Published private(set) var pinnedCreatorIDs: [UUID] = []
    @Published var articles: [ArchivedArticle] = []
    @Published var selectedArticleID: UUID?
    @Published var sidebarSelection: SidebarSelection? = .all {
        didSet {
            guard oldValue != sidebarSelection else { return }
            synchronizeSelectedArticleWithSidebar()
        }
    }
    @Published var archiveRoot: URL?
    @Published var isRunning = false
    @Published var statusMessage = "准备就绪"
    @Published var errorMessage: String?
    @Published var progress = SyncProgress()
    @Published var upicCapability = ImageHostCapability(name: "uPic 图床", version: nil, isAvailable: false, detail: "正在检测")
    @Published var imageHostChoice: ImageHostChoice = .local
    @Published var imageHostVerified = true
    @Published var hasS3Credentials = false
    @Published var s3Endpoint = ""
    @Published var s3Bucket = ""
    @Published var s3PublicBaseURL = ""
    @Published var s3Region = "auto"
    @Published var s3KeyPrefix = "x-archive"
    @Published var showingAddCreators = false
    @Published var showingSyncAllConfiguration = false
    @Published var showingConnectionSetup = false
    @Published var connectionSetupTarget: ConnectionSetupTarget = .overview
    @Published var downloadSheetPrefill = ""
    @Published var downloadSheetUsesArticleLinks = false
    @Published var showingCreatorArticleDiscovery = false
    @Published var creatorArticleDiscoveryRequests: [CreatorArticleDiscoveryRequest] = []
    @Published var creatorArticleDiscoveryIndex = 0
    @Published var showingBrowserCapture = false
    @Published private(set) var isDownloadProgressWindowVisible = false
    @Published var browserCaptureRequests: [BrowserCaptureRequest] = []
    @Published var browserCaptureIndex = 0
    @Published var downloadResultNotice: DownloadResultNotice?
    @Published var syncResultNotice: DownloadResultNotice?
    @Published var articlePendingDeletion: ArchivedArticle?
    @Published var creatorPendingDeletion: Creator?
    @Published var exactCaptureTaskPendingDeletion: ArchivedArticle?
    @Published var showingDeleteAllExactCaptureTasksConfirmation = false
    @Published private(set) var scheduledSyncEnabled = false
    @Published private(set) var scheduledSyncHour = 2
    @Published private(set) var scheduledSyncMinute = 0
    @Published private(set) var scheduledSyncArticleLimit = 10
    @Published private(set) var scheduledSyncLastRunAt: Date?
    @Published private(set) var scheduledSyncLastResult = "尚未执行过定时同步"
    @Published private(set) var isBootstrapped = false
    @Published private(set) var todayRefreshDate = Date()

    private var database: ArchiveDatabase?
    private var runningTask: Task<Void, Never>?
    private var browserCaptureSavedPostIDs = Set<String>()
    private var browserCaptureFailurePostIDs = Set<String>()
    private var browserCaptureSubscriptionPostIDs = Set<String>()
    private var browserCaptureFailureDetails: [String] = []
    private var discoveredCreatorArticles: [CreatorArticleListItem] = []
    private var browserCaptureStopRequested = false
    private var activeArchiveOperation: ActiveArchiveOperation = .download
    private var scheduledRunActive = false
    private var downloadProgressWindowController: NSWindowController?
    private var downloadProgressWindowDelegate: DownloadProgressWindowDelegate?
    private weak var downloadProgressAnchorWindow: NSWindow?
    private var downloadProgressWindowHiddenByUser = false
    private var todayRefreshTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private static let pinnedCreatorIDsDefaultsKey = "pinnedCreatorIDs"
    private static let maximumPinnedCreators = 5

    init() {
        if let savedPinnedIDs = defaults.array(forKey: Self.pinnedCreatorIDsDefaultsKey) as? [String] {
            pinnedCreatorIDs = savedPinnedIDs.compactMap(UUID.init)
        }
        if let path = defaults.string(forKey: "archiveRootPath") {
            archiveRoot = URL(fileURLWithPath: path, isDirectory: true)
        }
        let localDefaultMigrationKey = "didMakeLocalMediaStorageDefaultV1"
        if defaults.bool(forKey: localDefaultMigrationKey) {
            imageHostChoice = ImageHostChoice(rawValue: defaults.string(forKey: "imageHostChoice") ?? "") ?? .local
        } else {
            imageHostChoice = .local
            defaults.set(ImageHostChoice.local.rawValue, forKey: "imageHostChoice")
            defaults.set(true, forKey: localDefaultMigrationKey)
        }
        imageHostVerified = imageHostChoice == .local || defaults.bool(forKey: "imageHostVerified")
        scheduledSyncEnabled = defaults.bool(forKey: "scheduledSyncEnabled")
        scheduledSyncHour = defaults.object(forKey: "scheduledSyncHour") as? Int ?? 2
        scheduledSyncMinute = defaults.object(forKey: "scheduledSyncMinute") as? Int ?? 0
        scheduledSyncArticleLimit = defaults.object(forKey: "scheduledSyncArticleLimit") as? Int ?? 10
        scheduledSyncLastRunAt = defaults.object(forKey: "scheduledSyncLastRunAt") as? Date
        scheduledSyncLastResult = defaults.string(forKey: "scheduledSyncLastResult") ?? "尚未执行过定时同步"
        if let configurationData = defaults.data(forKey: "s3Configuration"),
           let configuration = try? JSONDecoder().decode(S3ImageHostConfiguration.self, from: configurationData) {
            s3Endpoint = configuration.endpoint.absoluteString
            s3Bucket = configuration.bucket
            s3PublicBaseURL = configuration.publicBaseURL.absoluteString
            s3Region = configuration.region
            s3KeyPrefix = configuration.keyPrefix
        }
        Task { await bootstrap() }
        Task { await refreshS3CredentialState() }
        todayRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                self.todayRefreshDate = Date()
            }
        }
        // Build 47 removes the retired X Developer API configuration entirely.
        // Delete any credential created by older builds without surfacing or
        // retaining its value.
        for key in ["xBearerToken", "xAPIBearerToken", "hasXToken"] {
            defaults.removeObject(forKey: key)
        }
        Task.detached(priority: .utility) {
            try? KeychainStore.delete(account: "x-api-bearer-token")
        }
    }

    deinit {
        todayRefreshTask?.cancel()
    }

    var filteredArticles: [ArchivedArticle] {
        switch sidebarSelection {
        case .all, .none:
            articles
        case .today:
            articles.filter {
                ArchiveSidebarStatistics.isPublishedToday($0.publishedAt, now: todayRefreshDate)
            }
        case .pending:
            articles.filter(ArchiveSidebarStatistics.isProcessing)
        case .failed:
            articles.filter(ArchiveSidebarStatistics.needsAttention)
        case .creator(let id):
            articles.filter { $0.creatorID == id }
        }
    }

    var sidebarStatistics: ArchiveSidebarStatistics {
        ArchiveSidebarStatistics(articles: articles)
    }

    var todayArticleCount: Int {
        articles.filter {
            ArchiveSidebarStatistics.isPublishedToday($0.publishedAt, now: todayRefreshDate)
        }.count
    }

    var selectedArticle: ArchivedArticle? {
        guard let selectedArticleID else { return nil }
        return articles.first { $0.id == selectedArticleID }
    }

    /// Keep the detail selection inside the active sidebar filter. Without this,
    /// switching to a status-only filter can leave the list bound to an article
    /// that is no longer in the current rows, which breaks NavigationSplitView.
    func synchronizeSelectedArticleWithSidebar() {
        selectedArticleID = ArchiveSidebarStatistics.resolvedArticleSelection(
            current: selectedArticleID,
            visibleIDs: filteredArticles.map(\.id)
        )
    }

    var currentBrowserCaptureRequest: BrowserCaptureRequest? {
        guard browserCaptureRequests.indices.contains(browserCaptureIndex) else { return nil }
        return browserCaptureRequests[browserCaptureIndex]
    }

    var currentCreatorArticleDiscoveryRequest: CreatorArticleDiscoveryRequest? {
        guard creatorArticleDiscoveryRequests.indices.contains(creatorArticleDiscoveryIndex) else { return nil }
        return creatorArticleDiscoveryRequests[creatorArticleDiscoveryIndex]
    }

    var pendingExactCaptureCount: Int {
        pendingExactCaptureArticles.count
    }

    var browserCaptureSubscriptionRequiredCount: Int {
        browserCaptureSubscriptionPostIDs.count
    }

    var pendingExactCaptureArticles: [ArchivedArticle] {
        articles.filter(ExactCaptureQueuePolicy.needsCapture)
    }

    var pinnedCreators: [Creator] {
        let creatorsByID = Dictionary(uniqueKeysWithValues: creators.map { ($0.id, $0) })
        return pinnedCreatorIDs.compactMap { creatorsByID[$0] }
    }

    var unpinnedCreators: [Creator] {
        let pinnedIDs = Set(pinnedCreatorIDs)
        return creators.filter { !pinnedIDs.contains($0.id) }
    }

    var canPinAnotherCreator: Bool {
        pinnedCreatorIDs.count < Self.maximumPinnedCreators
    }

    func isCreatorPinned(_ creator: Creator) -> Bool {
        pinnedCreatorIDs.contains(creator.id)
    }

    func pinnedCreatorIndex(of creator: Creator) -> Int? {
        pinnedCreatorIDs.firstIndex(of: creator.id)
    }

    func pinCreator(_ creator: Creator) {
        guard !isCreatorPinned(creator), canPinAnotherCreator else { return }
        pinnedCreatorIDs.append(creator.id)
        persistPinnedCreatorIDs()
    }

    func unpinCreator(_ creator: Creator) {
        guard let index = pinnedCreatorIndex(of: creator) else { return }
        pinnedCreatorIDs.remove(at: index)
        persistPinnedCreatorIDs()
    }

    func movePinnedCreators(fromOffsets offsets: IndexSet, toOffset offset: Int) {
        guard !offsets.isEmpty else { return }
        pinnedCreatorIDs.move(fromOffsets: offsets, toOffset: offset)
        persistPinnedCreatorIDs()
    }

    func movePinnedCreator(_ creator: Creator, by direction: Int) {
        guard let index = pinnedCreatorIndex(of: creator) else { return }
        let destination = index + direction
        guard pinnedCreatorIDs.indices.contains(destination) else { return }
        pinnedCreatorIDs.swapAt(index, destination)
        persistPinnedCreatorIDs()
    }

    private func persistPinnedCreatorIDs() {
        defaults.set(pinnedCreatorIDs.map(\.uuidString), forKey: Self.pinnedCreatorIDsDefaultsKey)
    }

    private func reconcilePinnedCreatorIDs() {
        let availableIDs = Set(creators.map(\.id))
        let reconciled = Array(pinnedCreatorIDs.filter { availableIDs.contains($0) }.prefix(Self.maximumPinnedCreators))
        guard reconciled != pinnedCreatorIDs else { return }
        pinnedCreatorIDs = reconciled
        persistPinnedCreatorIDs()
    }

    var enabledCreatorCount: Int {
        SyncAllCreatorPolicy.enabledUsernames(from: creators).count
    }

    var isSyncingTrackedCreators: Bool {
        if case .syncAll = activeArchiveOperation { return true }
        return false
    }

    var isRefreshingCreatorCounts: Bool {
        if case .refreshCounts = activeArchiveOperation { return true }
        return false
    }

    var activeSyncArticleLimit: Int? {
        guard case .syncAll(_, let articleLimit, _) = activeArchiveOperation else { return nil }
        return articleLimit
    }

    var activeSyncCreatorCount: Int? {
        guard case .syncAll(let creatorCount, _, _) = activeArchiveOperation else { return nil }
        return creatorCount
    }

    var activeSyncResolvesTotalCount: Bool {
        guard case .syncAll(_, _, let resolvesTotalCount) = activeArchiveOperation else { return false }
        return resolvesTotalCount
    }

    var configurationSummary: String {
        let folder = archiveRoot?.lastPathComponent ?? "未选择归档目录"
        let x = ChromeXSessionReader.hasLocalChromeProfile() ? "Chrome X 可用" : "Chrome X 未就绪"
        let storage = imageHostVerified ? "媒体存储已就绪" : "媒体存储未验证"
        return "\(x) · \(storage) · \(folder)"
    }

    var hasActiveDownloadProgress: Bool {
        showingCreatorArticleDiscovery || showingBrowserCapture
            || !creatorArticleDiscoveryRequests.isEmpty || !browserCaptureRequests.isEmpty
    }

    var imageHostDetail: String {
        if imageHostVerified {
            switch imageHostChoice {
            case .local: return "默认本地保存：图片 media/images，视频 media/videos"
            case .uPic: return "uPic 已验证；Markdown 使用图床链接，media 保留本地备份"
            case .s3: return "原生 S3/R2 真实上传验证通过"
            }
        }
        if imageHostChoice == .uPic, upicCapability.isAvailable {
            return upicCapability.detail
        }
        if imageHostChoice == .s3, hasS3Credentials {
            return "S3/R2 凭证已保存，尚未通过测试上传"
        }
        return "尚未配置并验证媒体存储"
    }

    func bootstrap() async {
        defer { isBootstrapped = true }
        if let archiveRoot {
            do {
                try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
                let migration = try ArchiveLayout.migrateLegacyLayout(in: archiveRoot)
                let openedDatabase = try ArchiveDatabase(url: Self.databaseURL(for: archiveRoot))
                database = openedDatabase
                try await migrateArticlePathsAndRebuildIndexes(
                    at: archiveRoot,
                    database: openedDatabase
                )
                try await reload()
                if migration.didChange {
                    statusMessage = "已把旧版博主目录安全迁移到 Blogger"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        upicCapability = await UPicAdapter().probe()
        if imageHostChoice == .local {
            setImageHostVerified(true)
        } else if !upicCapability.isAvailable, imageHostChoice == .uPic {
            setImageHostVerified(false)
        } else if imageHostChoice == .uPic, imageHostVerified {
            upicCapability.detail = "uPic 已验证；远程链接为主，本地 media 同步备份"
        }
    }

    func presentConnectionSetup(focusing target: ConnectionSetupTarget = .overview) {
        connectionSetupTarget = target
        showingConnectionSetup = true
    }

    func showDownloadProgressWindow() {
        guard hasActiveDownloadProgress else { return }
        downloadProgressWindowHiddenByUser = false
        presentDownloadProgressWindowIfAllowed()
    }

    func hideDownloadProgressWindow() {
        downloadProgressWindowHiddenByUser = true
        downloadProgressWindowController?.window?.orderOut(nil)
        isDownloadProgressWindowVisible = false
        statusMessage = "下载继续在后台执行；可点击工具栏的「显示下载进度」重新打开"
    }

    private func beginDownloadProgressSession() {
        downloadProgressWindowHiddenByUser = false
        downloadProgressAnchorWindow = resolveDownloadProgressAnchorWindow(
            excluding: downloadProgressWindowController?.window
        )
    }

    private func presentDownloadProgressWindowIfAllowed() {
        guard hasActiveDownloadProgress, !downloadProgressWindowHiddenByUser else { return }
        if downloadProgressWindowController == nil {
            let rootView = DownloadProgressRootView().environmentObject(self)
            let hostingController = NSHostingController(rootView: rootView)
            // The progress content changes from discovery to capture while the
            // same window stays alive. Do not let NSHostingController resize
            // that window to each SwiftUI view's preferred size, because the
            // unchanged origin would make the window visibly drift off-center.
            hostingController.sizingOptions = []
            let window = NSWindow(contentViewController: hostingController)
            window.title = "MarkX 下载进度"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 680))
            window.minSize = NSSize(width: 760, height: 590)
            window.isReleasedWhenClosed = false
            let delegate = DownloadProgressWindowDelegate(model: self)
            window.delegate = delegate
            downloadProgressWindowDelegate = delegate
            downloadProgressWindowController = NSWindowController(window: window)
        }
        guard let progressWindow = downloadProgressWindowController?.window else { return }
        if let currentAnchor = resolveDownloadProgressAnchorWindow(excluding: progressWindow) {
            downloadProgressAnchorWindow = currentAnchor
        }
        if let anchorWindow = downloadProgressAnchorWindow {
            centerDownloadProgressWindow(progressWindow, over: anchorWindow)
        }
        downloadProgressWindowController?.showWindow(nil)
        progressWindow.deminiaturize(nil)
        progressWindow.makeKeyAndOrderFront(nil)
        isDownloadProgressWindowVisible = true
    }

    private func resolveDownloadProgressAnchorWindow(excluding progressWindow: NSWindow?) -> NSWindow? {
        let preferredWindows = [NSApp.mainWindow, NSApp.keyWindow, downloadProgressAnchorWindow]
        for candidate in preferredWindows {
            guard let rootWindow = rootApplicationWindow(for: candidate),
                  rootWindow !== progressWindow,
                  rootWindow.styleMask.contains(.titled) else { continue }
            return rootWindow
        }

        return NSApp.windows.first { window in
            window !== progressWindow
                && window.isVisible
                && window.sheetParent == nil
                && window.level == .normal
                && window.styleMask.contains(.titled)
        }
    }

    private func rootApplicationWindow(for window: NSWindow?) -> NSWindow? {
        var rootWindow = window
        while let parent = rootWindow?.sheetParent {
            rootWindow = parent
        }
        return rootWindow
    }

    private func centerDownloadProgressWindow(_ progressWindow: NSWindow, over anchorWindow: NSWindow) {
        let anchorFrame = anchorWindow.frame
        let progressSize = progressWindow.frame.size
        var origin = NSPoint(
            x: anchorFrame.midX - progressSize.width / 2,
            y: anchorFrame.midY - progressSize.height / 2
        )

        if let visibleFrame = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            let maximumX = max(visibleFrame.minX, visibleFrame.maxX - progressSize.width)
            let maximumY = max(visibleFrame.minY, visibleFrame.maxY - progressSize.height)
            origin.x = min(max(origin.x, visibleFrame.minX), maximumX)
            origin.y = min(max(origin.y, visibleFrame.minY), maximumY)
        }

        // Position before ordering the window front so it never flashes at an
        // AppKit cascade location. Reopening repeats this calculation against
        // the main app window's latest position.
        progressWindow.setFrameOrigin(origin)
    }

    private func finishDownloadProgressWindow() {
        downloadProgressWindowController?.window?.orderOut(nil)
        isDownloadProgressWindowVisible = false
        downloadProgressWindowHiddenByUser = false
        downloadProgressAnchorWindow = nil
    }

    func saveScheduledSync(
        enabled: Bool,
        hour: Int,
        minute: Int,
        articleLimit: Int
    ) async -> Bool {
        let configuration = ScheduledSyncConfiguration(
            isEnabled: enabled,
            hour: hour,
            minute: minute,
            articleLimit: articleLimit
        )
        guard configuration.isValid else {
            errorMessage = "定时同步时间或文章数量无效"
            return false
        }
        if enabled {
            guard archiveRoot != nil else {
                errorMessage = "请先选择本地归档目录"
                return false
            }
            guard imageHostVerified else {
                errorMessage = "请先验证当前媒体存储，再启用定时同步"
                return false
            }
            guard enabledCreatorCount > 0 else {
                errorMessage = "还没有可同步的已跟踪博主"
                return false
            }
        }

        do {
            try await Task.detached(priority: .utility) {
                try ScheduledSyncLaunchAgentManager.apply(configuration)
            }.value
            scheduledSyncEnabled = enabled
            scheduledSyncHour = hour
            scheduledSyncMinute = minute
            scheduledSyncArticleLimit = articleLimit
            defaults.set(enabled, forKey: "scheduledSyncEnabled")
            defaults.set(hour, forKey: "scheduledSyncHour")
            defaults.set(minute, forKey: "scheduledSyncMinute")
            defaults.set(articleLimit, forKey: "scheduledSyncArticleLimit")
            statusMessage = enabled
                ? String(format: "已启用每日 %02d:%02d 后台同步", hour, minute)
                : "已关闭定时同步"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "xarticlearchiver",
              url.host?.lowercased() == "scheduled-sync" else { return }
        Task { await startScheduledSyncFromSystem() }
    }

    private func startScheduledSyncFromSystem() async {
        guard scheduledSyncEnabled else { return }
        for _ in 0..<200 where !isBootstrapped {
            try? await Task.sleep(for: .milliseconds(100))
        }

        let triggeredAt = Date()
        if isRunning {
            recordScheduledSyncResult(
                at: triggeredAt,
                message: "本次已跳过：上一个下载或同步任务仍在运行"
            )
            return
        }
        guard isBootstrapped, archiveRoot != nil else {
            recordScheduledSyncResult(at: triggeredAt, message: "本次未执行：本地归档目录未就绪")
            return
        }
        guard imageHostVerified else {
            recordScheduledSyncResult(at: triggeredAt, message: "本次未执行：当前媒体存储未通过验证")
            return
        }
        guard enabledCreatorCount > 0 else {
            recordScheduledSyncResult(at: triggeredAt, message: "本次未执行：没有已跟踪博主")
            return
        }

        scheduledRunActive = true
        recordScheduledSyncResult(
            at: triggeredAt,
            message: "正在后台同步 \(enabledCreatorCount) 位博主，每位最近 \(scheduledSyncArticleLimit) 篇"
        )
        startSyncAll(articleLimit: scheduledSyncArticleLimit, resolveTotalCount: false)
        if !NSApp.isActive {
            NSApp.hide(nil)
        }
    }

    private func publishSyncResult(
        title: String,
        message: String,
        metrics: [DownloadResultMetric] = []
    ) {
        if scheduledRunActive {
            scheduledRunActive = false
            let compact = message.replacingOccurrences(of: "\n", with: " ")
            recordScheduledSyncResult(at: Date(), message: "\(title)：\(compact)")
        } else {
            syncResultNotice = DownloadResultNotice(title: title, message: message, metrics: metrics)
        }
    }

    private func recordScheduledSyncResult(at date: Date, message: String) {
        scheduledSyncLastRunAt = date
        scheduledSyncLastResult = message
        defaults.set(date, forKey: "scheduledSyncLastRunAt")
        defaults.set(message, forKey: "scheduledSyncLastResult")
    }

    private func refreshS3CredentialState() async {
        do {
            let credentialState = try await Task.detached(priority: .userInitiated) {
                let access = try KeychainStore.read(account: KeychainStore.s3AccessKeyAccount)
                let secret = try KeychainStore.read(account: KeychainStore.s3SecretKeyAccount)
                return access?.isEmpty == false && secret?.isEmpty == false
            }.value
            hasS3Credentials = credentialState
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseArchiveFolder() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = archiveRoot == nil ? "选择 X 长文归档目录" : "同步并切换 X 长文归档目录"
        panel.message = archiveRoot == nil
            ? "文章、图片缓存和资料库会保存在这个目录中。"
            : "当前资料库会完整复制到新目录；确认复制和校验成功后，应用才会切换。旧目录将保留。"
        panel.prompt = archiveRoot == nil ? "使用此目录" : "同步并切换"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let destination = selectedURL.standardizedFileURL
        guard let currentRoot = archiveRoot?.standardizedFileURL else {
            archiveRoot = destination
            defaults.set(destination.path, forKey: "archiveRootPath")
            Task { await configureDatabase(at: destination) }
            return
        }
        guard currentRoot.path != destination.path else {
            statusMessage = "当前已经在使用这个归档目录"
            return
        }
        synchronizeAndSwitchArchiveFolder(from: currentRoot, to: destination)
    }

    private func synchronizeAndSwitchArchiveFolder(from source: URL, to destination: URL) {
        guard !isRunning else { return }
        runningTask = Task {
            isRunning = true
            errorMessage = nil
            progress = SyncProgress(stage: "正在准备同步现有资料库")
            defer {
                isRunning = false
                runningTask = nil
            }

            do {
                if let database {
                    try await database.checkpointForDirectorySync()
                }
                let replaceablePaths = try await approvedRetryFiles(
                    from: source,
                    to: destination
                )
                progress.stage = "正在复制文章、图片缓存和来源快照"
                statusMessage = progress.stage

                let copyTask = Task.detached(priority: .userInitiated) {
                    try ArchiveDirectorySynchronizer.synchronize(
                        from: source,
                        to: destination,
                        replaceableRelativePaths: replaceablePaths
                    )
                }
                let result = try await withTaskCancellationHandler {
                    try await copyTask.value
                } onCancel: {
                    copyTask.cancel()
                }
                try Task.checkCancellation()

                progress.stage = "正在校验新目录并更新文章路径"
                try ArchiveLayout.migrateLegacyLayout(in: destination)
                let destinationDatabase = try ArchiveDatabase(url: Self.databaseURL(for: destination))
                let copiedArticles = try await destinationDatabase.loadArticles()
                for var article in copiedArticles {
                    guard let currentPath = article.markdownPath,
                          let rebasedPath = ArchiveDirectorySynchronizer.rebasedPath(
                            currentPath,
                            from: source,
                            to: destination
                          ) else { continue }
                    guard FileManager.default.fileExists(atPath: rebasedPath) else {
                        throw ArchiveDirectorySyncError.fileOperation(
                            "新目录缺少文章文件：\(URL(fileURLWithPath: rebasedPath).lastPathComponent)"
                        )
                    }
                    article.markdownPath = rebasedPath
                    try await destinationDatabase.upsertArticle(article)
                }
                try await migrateArticlePathsAndRebuildIndexes(
                    at: destination,
                    database: destinationDatabase
                )

                database = destinationDatabase
                archiveRoot = destination
                defaults.set(destination.path, forKey: "archiveRootPath")
                try await reload()

                let size = ByteCountFormatter.string(
                    fromByteCount: result.copiedByteCount,
                    countStyle: .file
                )
                progress.stage = "目录切换完成"
                statusMessage = "已同步 \(articles.count) 篇文章、\(result.copiedFileCount) 个文件（\(size)）"
            } catch is CancellationError {
                progress.stage = "目录切换已停止"
                statusMessage = "仍在使用原归档目录；新目录中的已复制文件可在下次同步时复用"
            } catch {
                progress.stage = "目录切换失败"
                statusMessage = "仍在使用原归档目录"
                errorMessage = error.localizedDescription
            }
        }
    }

    /// A failed switch from an earlier build may have opened the copied SQLite
    /// database before discovering a missing Markdown file. Opening SQLite can
    /// change page bytes even when every logical row is unchanged, so a plain
    /// byte comparison would make that otherwise safe retry impossible.
    /// Approve replacement only when creators and articles are logically
    /// identical after normalizing their archive-relative Markdown paths.
    private func approvedRetryFiles(from source: URL, to destination: URL) async throws -> Set<String> {
        let relativeDatabasePath = ".x-article-archiver/archive.sqlite"
        let sourceDatabaseURL = Self.databaseURL(for: source)
        let destinationDatabaseURL = Self.databaseURL(for: destination)
        guard FileManager.default.fileExists(atPath: destinationDatabaseURL.path),
              !FileManager.default.contentsEqual(
                atPath: sourceDatabaseURL.path,
                andPath: destinationDatabaseURL.path
              ) else { return [] }
        guard let sourceDatabase = database else { return [] }

        let sourceCreators = try await sourceDatabase.loadCreators()
        let sourceArticles = try await sourceDatabase.loadArticles()
        let matches: Bool
        do {
            let destinationDatabase = try ArchiveDatabase(url: destinationDatabaseURL)
            let destinationCreators = try await destinationDatabase.loadCreators()
            let destinationArticles = try await destinationDatabase.loadArticles()
            matches = Set(sourceCreators) == Set(destinationCreators)
                && Self.normalizedArticles(sourceArticles, source: source, destination: destination)
                    == Self.normalizedArticles(destinationArticles, source: source, destination: destination)
            try await destinationDatabase.closeAfterCheckpointForDirectorySync()
        }

        guard matches else {
            throw ArchiveDirectorySyncError.conflictingFile(relativeDatabasePath)
        }
        // The destination connection is closed when the scope above ends and
        // its WAL has been checkpointed. Remove only its now-disposable SQLite
        // sidecars so the approved main-file replacement cannot replay stale
        // pages on the next open.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: destinationDatabaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        return [relativeDatabasePath]
    }

    private static func normalizedArticles(
        _ articles: [ArchivedArticle],
        source: URL,
        destination: URL
    ) -> Set<ArchivedArticle> {
        Set(articles.map { original in
            var article = original
            if let path = article.markdownPath {
                article.markdownPath = ArchiveDirectorySynchronizer.relativePath(for: path, under: source)
                    ?? ArchiveDirectorySynchronizer.relativePath(for: path, under: destination)
                    ?? path
            }
            return article
        })
    }

    func presentDownloadSheet(for creator: Creator? = nil) {
        downloadSheetPrefill = creator.map { "@\($0.username)" } ?? ""
        downloadSheetUsesArticleLinks = false
        showingAddCreators = true
    }

    func presentArticleLinksSheet(prefill: String = "") {
        downloadSheetPrefill = prefill
        downloadSheetUsesArticleLinks = true
        showingAddCreators = true
    }

    func testUPic() async -> Bool {
        selectImageHost(.uPic)
        let installation = UPicAdapter()
        upicCapability = await installation.probe()
        guard upicCapability.isAvailable else {
            setImageHostVerified(false)
            return false
        }
        do {
            let adapter = UPicAdapter()
            guard let archiveRoot else {
                throw ImagePipelineError.hostUnavailable("请先选择本地归档目录")
            }
            statusMessage = "正在通过 uPic 图床上传无隐私测试图…"
            // The App Store build of uPic is sandboxed. Staging the probe inside
            // the selected archive root verifies the exact filesystem scope that
            // will later contain image/video cache files; another app's private
            // temporary directory is intentionally not readable by uPic.
            let remote = try await uploadSyntheticTestImage(
                using: adapter,
                stagingRoot: archiveRoot.appending(
                    path: ".x-article-archiver/uPic-connection-tests",
                    directoryHint: .isDirectory
                )
            )
            upicCapability.detail = "已验证 uPic：\(remote.host ?? "远程图床")；文章媒体将同时保存到本地"
            setImageHostVerified(true)
            statusMessage = "uPic 测试通过：Markdown 用远程链接，本地保留备份"
            return true
        } catch {
            setImageHostVerified(false)
            errorMessage = error.localizedDescription
            upicCapability.detail = error.localizedDescription
            statusMessage = "uPic 图床测试失败"
            return false
        }
    }

    func saveAndTestS3(accessKey: String, secretKey: String) async -> Bool {
        do {
            guard let endpoint = URL(string: s3Endpoint), let publicBase = URL(string: s3PublicBaseURL) else {
                throw S3ImageHostError.invalidConfiguration("Endpoint 或公开访问地址格式不正确")
            }
            let existingCredentials = try await Task.detached(priority: .userInitiated) {
                (
                    access: try KeychainStore.read(account: KeychainStore.s3AccessKeyAccount) ?? "",
                    secret: try KeychainStore.read(account: KeychainStore.s3SecretKeyAccount) ?? ""
                )
            }.value
            let existingAccess = existingCredentials.access
            let existingSecret = existingCredentials.secret
            let actualAccess = accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? existingAccess : accessKey
            let actualSecret = secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? existingSecret : secretKey
            let configuration = S3ImageHostConfiguration(
                endpoint: endpoint,
                bucket: s3Bucket,
                publicBaseURL: publicBase,
                region: s3Region,
                keyPrefix: s3KeyPrefix
            )
            let adapter = S3ImageHostAdapter(configuration: configuration, accessKey: actualAccess, secretKey: actualSecret)
            let capability = await adapter.probe()
            guard capability.isAvailable else { throw S3ImageHostError.invalidConfiguration(capability.detail) }
            statusMessage = "正在测试原生 S3/R2 上传…"
            let remote = try await uploadSyntheticTestImage(using: adapter)
            try await Task.detached(priority: .utility) {
                try KeychainStore.save(actualAccess, account: KeychainStore.s3AccessKeyAccount)
                try KeychainStore.save(actualSecret, account: KeychainStore.s3SecretKeyAccount)
            }.value
            defaults.set(try JSONEncoder().encode(configuration), forKey: "s3Configuration")
            imageHostChoice = .s3
            defaults.set(ImageHostChoice.s3.rawValue, forKey: "imageHostChoice")
            hasS3Credentials = true
            setImageHostVerified(true)
            statusMessage = "S3/R2 图床测试通过：\(remote.host ?? "远程图床")"
            return true
        } catch {
            setImageHostVerified(false)
            errorMessage = error.localizedDescription
            statusMessage = "S3/R2 图床测试失败"
            return false
        }
    }

    func selectImageHost(_ choice: ImageHostChoice) {
        guard imageHostChoice != choice else { return }
        imageHostChoice = choice
        defaults.set(choice.rawValue, forKey: "imageHostChoice")
        if choice == .local {
            setImageHostVerified(true)
            statusMessage = "已切换为默认本地存储"
        } else {
            invalidateImageHostVerification()
        }
    }

    func invalidateImageHostVerification() {
        guard imageHostChoice != .local else {
            setImageHostVerified(true)
            return
        }
        guard imageHostVerified else { return }
        setImageHostVerified(false)
        statusMessage = "媒体存储配置已变更，请重新测试"
    }

    func removeS3Credentials() {
        do {
            try KeychainStore.delete(account: KeychainStore.s3AccessKeyAccount)
            try KeychainStore.delete(account: KeychainStore.s3SecretKeyAccount)
            hasS3Credentials = false
            invalidateImageHostVerification()
            statusMessage = "S3/R2 凭证已从钥匙串移除"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addAndArchiveCreators(
        input: String,
        mode: ArchiveMode,
        articleLimit: Int = 10,
        resolveTotalCount: Bool = false
    ) {
        guard !isRunning else { return }
        let handles = HandleParser.parse(input)
        guard !handles.isEmpty else {
            errorMessage = "没有识别到有效的 X 账号"
            return
        }
        guard archiveRoot != nil else {
            errorMessage = "请先选择本地归档目录"
            showingConnectionSetup = true
            return
        }
        guard imageHostVerified else {
            errorMessage = "请先完成当前媒体存储验证"
            showingConnectionSetup = true
            return
        }
        guard mode == .fullArchive || (1...100).contains(articleLimit) else {
            errorMessage = "下载数量必须在 1 到 100 之间"
            return
        }
        activeArchiveOperation = .download
        showingAddCreators = false
        beginCreatorArticleDiscovery(
            handles: handles,
            maximumArticles: mode == .recentWindow ? articleLimit : nil,
            resolvesTotalCount: mode == .fullArchive || resolveTotalCount,
            countOnly: false
        )
    }

    func requestSyncAll() {
        guard !isRunning else { return }
        guard enabledCreatorCount > 0 else {
            errorMessage = "还没有可同步的已跟踪博主"
            return
        }
        syncResultNotice = nil
        showingSyncAllConfiguration = true
    }

    func startSyncAll(articleLimit: Int, resolveTotalCount: Bool = false) {
        guard !isRunning else { return }
        guard (1...100).contains(articleLimit) else {
            errorMessage = "同步数量必须在 1 到 100 之间"
            return
        }
        guard archiveRoot != nil else {
            errorMessage = "请先选择本地归档目录"
            return
        }
        guard imageHostVerified else {
            errorMessage = "请先在连接设置中完成一次真实图片上传验证"
            return
        }
        let handles = SyncAllCreatorPolicy.enabledUsernames(from: creators)
        guard !handles.isEmpty else {
            showingSyncAllConfiguration = false
            errorMessage = "还没有可同步的已跟踪博主"
            return
        }
        activeArchiveOperation = .syncAll(
            creatorCount: handles.count,
            articleLimit: articleLimit,
            resolvesTotalCount: resolveTotalCount
        )
        beginCreatorArticleDiscovery(
            handles: handles,
            maximumArticles: articleLimit,
            resolvesTotalCount: resolveTotalCount,
            countOnly: false
        )
    }

    func refreshCreatorArticleCount(_ creator: Creator) {
        guard !isRunning else { return }
        let username = creator.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return }
        activeArchiveOperation = .refreshCounts(creatorCount: 1)
        beginCreatorArticleDiscovery(
            handles: [username],
            maximumArticles: nil,
            resolvesTotalCount: true,
            countOnly: true
        )
    }

    /// Discovers exact Article status URLs from each creator's dedicated
    /// `/articles` page. This intentionally never calls the timeline or search
    /// endpoints: regular Posts are not read, counted, or billed.
    private func beginCreatorArticleDiscovery(
        handles: [String],
        maximumArticles: Int?,
        resolvesTotalCount: Bool,
        countOnly: Bool
    ) {
        var seen = Set<String>()
        let uniqueHandles = handles.filter { seen.insert($0.lowercased()).inserted }
        guard !uniqueHandles.isEmpty, !isRunning else { return }
        beginDownloadProgressSession()

        let isClosingInputSheet = showingAddCreators || showingSyncAllConfiguration
        creatorArticleDiscoveryRequests = uniqueHandles.map {
            CreatorArticleDiscoveryRequest(
                username: $0,
                maximumArticles: maximumArticles,
                resolvesTotalCount: resolvesTotalCount,
                countOnly: countOnly
            )
        }
        creatorArticleDiscoveryIndex = 0
        discoveredCreatorArticles = []
        errorMessage = nil
        progress = SyncProgress(
            stage: isRefreshingCreatorCounts
                ? "正在刷新 \(uniqueHandles.count) 位博主的线上文章总数"
                : isSyncingTrackedCreators
                    ? (resolvesTotalCount
                        ? "正在后台同步 \(uniqueHandles.count) 位已跟踪博主并获取线上总数"
                        : "正在后台快速同步 \(uniqueHandles.count) 位已跟踪博主")
                    : (resolvesTotalCount
                        ? "正在打开 X Articles 专属列表并获取线上总数"
                        : "正在打开 X Articles 专属列表并读取最近文章")
        )
        statusMessage = isRefreshingCreatorCounts
            ? "正在完整扫描 Articles 列表，只更新线上总数，不下载文章；X API 调用为 0"
            : isSyncingTrackedCreators
                ? (resolvesTotalCount
                    ? "后台同步已开始；先获取每位博主线上总数，再按范围处理文章；X API 调用为 0"
                    : "后台快速同步已开始；只读取每位博主最近文章，不扫描完整历史；X API 调用为 0")
                : (resolvesTotalCount
                    ? "先读取完整 Articles 列表获取线上总数，再按范围下载；不扫描普通 Post，X API 调用为 0"
                    : "只读取 Articles 列表最近文章，再逐篇下载；线上总数可稍后手动刷新；X API 调用为 0")
        isRunning = true
        showingAddCreators = false
        showingSyncAllConfiguration = false
        if isClosingInputSheet {
            // Let SwiftUI finish dismissing the input sheet before presenting
            // the browser sheet. Presenting both in one update can drop the
            // second presentation on macOS.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard let self, self.isRunning,
                      !self.creatorArticleDiscoveryRequests.isEmpty else { return }
                self.showingCreatorArticleDiscovery = true
                self.presentDownloadProgressWindowIfAllowed()
            }
        } else {
            showingCreatorArticleDiscovery = true
            presentDownloadProgressWindowIfAllowed()
        }
    }

    func completeCreatorArticleDiscovery(
        _ result: CreatorArticleDiscoveryResult,
        for request: CreatorArticleDiscoveryRequest
    ) async {
        guard request.id == currentCreatorArticleDiscoveryRequest?.id else { return }
        if let knownArticleCount = result.knownArticleCount, let database {
            do {
                let existingCreator = try await database.creator(username: request.username)
                var creator = existingCreator ?? Creator(
                        xUserID: "browser:\(request.username.lowercased())",
                        username: request.username,
                        displayName: "@\(request.username)"
                    )
                creator.knownArticleCount = knownArticleCount
                if !request.countOnly || existingCreator == nil {
                    creator.isEnabled = true
                }
                try await database.upsertCreator(creator)
                if let index = creators.firstIndex(where: { $0.id == creator.id }) {
                    creators[index] = creator
                } else {
                    creators.append(creator)
                    creators.sort { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
                }
            } catch {
                errorMessage = "无法保存 @\(request.username) 的文章总数：\(error.localizedDescription)"
            }
        }
        if request.countOnly {
            guard result.knownArticleCount != nil else {
                creatorArticleDiscoveryFailed(
                    BrowserArticleCaptureError.pageNotReady("Articles 列表未到达底部，无法确认线上文章总数")
                )
                return
            }
            let next = creatorArticleDiscoveryIndex + 1
            if creatorArticleDiscoveryRequests.indices.contains(next) {
                creatorArticleDiscoveryIndex = next
                progress.stage = "正在刷新第 \(next + 1) / \(creatorArticleDiscoveryRequests.count) 位博主的线上文章总数"
                return
            }

            let creatorCount = creatorArticleDiscoveryRequests.count
            showingCreatorArticleDiscovery = false
            creatorArticleDiscoveryRequests = []
            creatorArticleDiscoveryIndex = 0
            discoveredCreatorArticles = []
            isRunning = false
            finishDownloadProgressWindow()
            progress.stage = "线上文章总数刷新完成"
            statusMessage = "已刷新 \(creatorCount) 位博主的线上文章总数；本次没有下载文章，X API 调用为 0"
            downloadResultNotice = DownloadResultNotice(
                title: "线上文章总数已刷新",
                message: "已完整扫描 Articles 列表并更新 \(creatorCount) 位博主的线上文章总数。本次没有下载文章，X API 调用为 0。",
                metrics: [
                    DownloadResultMetric(id: "creators", label: "刷新博主", value: "\(creatorCount)", systemImage: "person.2.fill", tone: .accent),
                    DownloadResultMetric(id: "status", label: "总数状态", value: "已更新", systemImage: "number.circle.fill", tone: .positive),
                    DownloadResultMetric(id: "downloaded", label: "下载文章", value: "0", systemImage: "arrow.down.circle", tone: .neutral)
                ]
            )
            activeArchiveOperation = .download
            return
        }
        var knownPostIDs = Set(discoveredCreatorArticles.map(\.link.postID))
        for item in result.items where knownPostIDs.insert(item.link.postID).inserted {
            discoveredCreatorArticles.append(item)
        }
        progress.discoveredArticles = discoveredCreatorArticles.count

        let next = creatorArticleDiscoveryIndex + 1
        if creatorArticleDiscoveryRequests.indices.contains(next) {
            creatorArticleDiscoveryIndex = next
            progress.stage = isSyncingTrackedCreators
                ? "正在同步第 \(next + 1) / \(creatorArticleDiscoveryRequests.count) 位博主"
                : "正在读取第 \(next + 1) / \(creatorArticleDiscoveryRequests.count) 位博主的 Articles 列表"
            return
        }

        let discovered = discoveredCreatorArticles
        showingCreatorArticleDiscovery = false
        creatorArticleDiscoveryRequests = []
        creatorArticleDiscoveryIndex = 0
        discoveredCreatorArticles = []
        isRunning = false

        guard !discovered.isEmpty else {
            finishDownloadProgressWindow()
            if let creatorCount = activeSyncCreatorCount,
               let articleLimit = activeSyncArticleLimit {
                progress.stage = "同步完成：没有发现可检查的 X Article"
                statusMessage = "已检查 \(creatorCount) 位博主；没有发现文章，X API 调用为 0"
                publishSyncResult(
                    title: "同步完成",
                    message: "已检查 \(creatorCount) 位已跟踪博主的最近 \(articleLimit) 篇 X Article，未发现可下载文章。本次 X API 调用为 0。",
                    metrics: [
                        DownloadResultMetric(id: "creators", label: "博主", value: "\(creatorCount)", systemImage: "person.2.fill", tone: .accent),
                        DownloadResultMetric(id: "checked", label: "检查文章", value: "0", systemImage: "doc.text.magnifyingglass", tone: .neutral),
                        DownloadResultMetric(id: "saved", label: "新增保存", value: "0", systemImage: "checkmark.circle.fill", tone: .positive)
                    ]
                )
            } else {
                progress.stage = "没有发现 X Article"
                statusMessage = "Articles 专属列表中没有发现文章；X API 调用为 0"
                downloadResultNotice = DownloadResultNotice(
                    title: "没有发现文章",
                    message: "目标博主的 Articles 专属列表中没有找到可下载的 X Article。",
                    metrics: [
                        DownloadResultMetric(id: "checked", label: "检查文章", value: "0", systemImage: "doc.text.magnifyingglass", tone: .neutral),
                        DownloadResultMetric(id: "saved", label: "新增保存", value: "0", systemImage: "checkmark.circle.fill", tone: .positive)
                    ]
                )
            }
            return
        }
        progress.stage = isSyncingTrackedCreators
            ? "已检查 \(discovered.count) 篇，正在跳过已同步文章"
            : "已发现 \(discovered.count) 篇，正在建立正文下载队列"
        statusMessage = isSyncingTrackedCreators
            ? "已从 Articles 专属列表检查 \(discovered.count) 篇，正在过滤已同步文章"
            : "已从 Articles 专属列表发现 \(discovered.count) 篇；X API 调用为 0"
        prepareDirectBrowserCapture(
            links: discovered.map(\.link),
            refreshExisting: false,
            preferredTitles: Dictionary(
                discovered.map { ($0.link.postID, $0.title) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    func creatorArticleDiscoveryFailed(_ error: Error) {
        showingCreatorArticleDiscovery = false
        creatorArticleDiscoveryRequests = []
        creatorArticleDiscoveryIndex = 0
        discoveredCreatorArticles = []
        isRunning = false
        finishDownloadProgressWindow()
        if isRefreshingCreatorCounts {
            progress.stage = "线上文章总数刷新失败"
            statusMessage = "线上文章总数刷新未完成；没有下载文章，也没有调用 X API"
            downloadResultNotice = DownloadResultNotice(
                title: "线上文章总数未刷新",
                message: "没有下载文章。\n\n原因：\(error.localizedDescription)\n\n请确认 Chrome 已登录 X 后重试。",
                metrics: [
                    DownloadResultMetric(id: "status", label: "总数状态", value: "未完成", systemImage: "number.circle", tone: .danger),
                    DownloadResultMetric(id: "downloaded", label: "下载文章", value: "0", systemImage: "arrow.down.circle", tone: .neutral)
                ]
            )
            activeArchiveOperation = .download
        } else if isSyncingTrackedCreators {
            progress.stage = "同步失败"
            statusMessage = "同步未完成；没有调用 X API"
            publishSyncResult(
                title: "同步未完成",
                message: "本次同步已停止，已完成的本地归档保留。\n\n原因：\(error.localizedDescription)\n\n请确认 Chrome 已登录 X 后重试。",
                metrics: [
                    DownloadResultMetric(id: "status", label: "同步状态", value: "未完成", systemImage: "exclamationmark.triangle.fill", tone: .danger),
                    DownloadResultMetric(id: "saved", label: "已保存", value: "\(progress.completedArticles)", systemImage: "checkmark.circle.fill", tone: .positive),
                    DownloadResultMetric(id: "failed", label: "失败", value: "\(progress.failedArticles)", systemImage: "xmark.circle.fill", tone: .danger)
                ]
            )
        } else {
            progress.stage = "Articles 列表读取失败"
            statusMessage = "没有调用 X API；请确认 Chrome 已登录 X 后重试"
            downloadResultNotice = DownloadResultNotice(
                title: "没有完成文章发现",
                message: "没有下载任何文章。\n\n原因：\(error.localizedDescription)\n\n请确认 Chrome 已登录 X 后重试。",
                metrics: [
                    DownloadResultMetric(id: "status", label: "发现状态", value: "未完成", systemImage: "exclamationmark.triangle.fill", tone: .danger),
                    DownloadResultMetric(id: "downloaded", label: "下载文章", value: "0", systemImage: "arrow.down.circle", tone: .neutral)
                ]
            )
        }
    }

    func closeCreatorArticleDiscovery() {
        showingCreatorArticleDiscovery = false
        creatorArticleDiscoveryRequests = []
        creatorArticleDiscoveryIndex = 0
        discoveredCreatorArticles = []
        isRunning = false
        finishDownloadProgressWindow()
        progress.stage = isRefreshingCreatorCounts
            ? "已停止线上文章总数刷新"
            : isSyncingTrackedCreators ? "已停止同步" : "已停止文章列表发现"
        let wasRefreshingCreatorCounts = isRefreshingCreatorCounts
        statusMessage = wasRefreshingCreatorCounts
            ? "已停止线上文章总数刷新；本次没有下载文章"
            : isSyncingTrackedCreators
                ? "已停止同步；已完成的本地归档保留"
                : "已停止；本次没有调用 X API"
        if wasRefreshingCreatorCounts {
            activeArchiveOperation = .download
        }
    }

    func archiveArticleLinks(input: String, refreshExisting: Bool = false) {
        guard !isRunning else { return }
        let links = XArticleURLParser.parse(input)
        guard !links.isEmpty else {
            errorMessage = "没有识别到有效的 X Article status 链接"
            return
        }
        guard links.count <= 500 else {
            errorMessage = "一次最多下载 500 条文章链接"
            return
        }
        guard archiveRoot != nil else {
            errorMessage = "请先选择本地归档目录"
            showingConnectionSetup = true
            return
        }
        guard imageHostVerified else {
            errorMessage = "请先完成当前媒体存储验证"
            showingConnectionSetup = true
            return
        }
        activeArchiveOperation = .download
        showingAddCreators = false
        beginDownloadProgressSession()
        prepareDirectBrowserCapture(links: links, refreshExisting: refreshExisting)
    }

    func captureSelectedArticleExactly() {
        guard !isRunning else { return }
        guard let article = selectedArticle,
              let link = XArticleURLParser.parse(article.sourceURL.absoluteString).first else {
            errorMessage = "这篇文章没有可用的 X status 链接"
            return
        }
        let creator = creators.first(where: { $0.id == article.creatorID })
            ?? Creator(
                id: article.creatorID,
                xUserID: "browser:\(article.authorHandle.lowercased())",
                username: article.authorHandle,
                displayName: "@\(article.authorHandle)"
            )
        activeArchiveOperation = .download
        beginDownloadProgressSession()
        beginBrowserCapture([
            BrowserCaptureRequest(
                link: link,
                creator: creator,
                displayTitle: article.title,
                publishedAt: article.publishedAt,
                sourceArticleID: article.sourceArticleID
            )
        ])
    }

    func resumePendingBrowserCaptures() {
        guard !isRunning else { return }
        let pending = pendingExactCaptureArticles
        let requests = pending.compactMap { article -> BrowserCaptureRequest? in
            guard let link = XArticleURLParser.parse(article.sourceURL.absoluteString).first else { return nil }
            let creator = creators.first(where: { $0.id == article.creatorID })
                ?? Creator(
                    id: article.creatorID,
                    xUserID: "browser:\(article.authorHandle.lowercased())",
                    username: article.authorHandle,
                    displayName: "@\(article.authorHandle)"
                )
            return BrowserCaptureRequest(
                link: link,
                creator: creator,
                displayTitle: article.title,
                publishedAt: article.publishedAt,
                sourceArticleID: article.sourceArticleID
            )
        }
        guard !requests.isEmpty else {
            statusMessage = "没有待完成的精确排版采集"
            return
        }
        activeArchiveOperation = .download
        beginDownloadProgressSession()
        beginBrowserCapture(requests)
    }

    func advanceBrowserCapture() {
        guard !browserCaptureStopRequested else {
            showingBrowserCapture = false
            browserCaptureRequests = []
            browserCaptureIndex = 0
            finishDownloadProgressWindow()
            statusMessage = isSyncingTrackedCreators
                ? "已停止同步；已完成归档保留，未完成任务可继续"
                : "已停止精确排版采集；未完成任务已保留"
            return
        }
        let next = browserCaptureIndex + 1
        if browserCaptureRequests.indices.contains(next) {
            browserCaptureIndex = next
            statusMessage = "已完成 \(next) / \(browserCaptureRequests.count)，正在自动处理下一篇"
        } else {
            let total = browserCaptureRequests.count
            let completed = browserCaptureSavedPostIDs.count
            let subscriptionRequired = browserCaptureSubscriptionPostIDs.count
            let failed = max(0, browserCaptureFailurePostIDs.count - subscriptionRequired)
            let accountedPostIDs = browserCaptureSavedPostIDs.union(browserCaptureFailurePostIDs)
            let unaccounted = browserCaptureRequests.lazy.filter {
                !accountedPostIDs.contains($0.link.postID)
            }.count
            let skipped = progress.skippedArticles
            let images = progress.uploadedImages
            let videos = progress.uploadedVideos
            let failureNote = browserCaptureFailureDetails.isEmpty
                ? ""
                : "\n\n未完成：\(browserCaptureFailureDetails.prefix(3).joined(separator: "；"))"
            let pending = pendingExactCaptureArticles
            let attentionRemaining = pending.lazy.filter(ArchiveSidebarStatistics.needsAttention).count
            let waitingRemaining = max(0, pending.count - attentionRemaining)
            let pendingTotal = waitingRemaining + attentionRemaining + unaccounted
            let outstandingNote = pending.isEmpty
                ? ""
                : "\n\n资料库仍有等待继续 \(waitingRemaining) 篇、需要处理 \(attentionRemaining) 篇；本次队列结束不代表这些文章已经完成。可在左侧对应分类中重新开始。"
            let hasUnfinishedWork = !pending.isEmpty || unaccounted > 0
            let unaccountedNote = unaccounted == 0
                ? ""
                : "\n\n另有 \(unaccounted) 篇没有得到已保存或明确失败结果，系统未把它们计为完成。"
            showingBrowserCapture = false
            browserCaptureRequests = []
            browserCaptureIndex = 0
            browserCaptureSavedPostIDs.removeAll()
            browserCaptureSubscriptionPostIDs.removeAll()
            finishDownloadProgressWindow()
            if let creatorCount = activeSyncCreatorCount,
               let articleLimit = activeSyncArticleLimit {
                let checked = total + skipped
                progress.stage = hasUnfinishedWork ? "本次同步结束，资料库仍有未完成文章" : "全部博主同步完成"
                statusMessage = hasUnfinishedWork
                    ? "本次同步结束：保存 \(completed) 篇，跳过 \(skipped) 篇，需订阅 \(subscriptionRequired) 篇，失败 \(failed) 篇；仍有未完成任务"
                    : "同步完成：保存 \(completed) 篇，跳过 \(skipped) 篇，失败 0 篇"
                let metrics = [
                    DownloadResultMetric(id: "creators", label: "博主", value: "\(creatorCount)", systemImage: "person.2.fill", tone: .accent),
                    DownloadResultMetric(id: "checked", label: "检查文章", value: "\(checked)", systemImage: "doc.text.magnifyingglass", tone: .accent),
                    DownloadResultMetric(id: "saved", label: "新增保存", value: "\(completed)", systemImage: "checkmark.circle.fill", tone: .positive),
                    DownloadResultMetric(id: "skipped", label: "已跳过", value: "\(skipped)", systemImage: "forward.end.fill", tone: .neutral),
                    DownloadResultMetric(id: "subscription", label: "需订阅", value: "\(subscriptionRequired)", systemImage: "lock.fill", tone: subscriptionRequired > 0 ? .warning : .neutral),
                    DownloadResultMetric(id: "failed", label: "失败", value: "\(failed)", systemImage: "xmark.circle.fill", tone: failed > 0 ? .danger : .neutral),
                    DownloadResultMetric(id: "images", label: "图片", value: "\(images)", systemImage: "photo.fill", tone: .accent),
                    DownloadResultMetric(id: "videos", label: "视频", value: "\(videos)", systemImage: "video.fill", tone: .accent),
                    DownloadResultMetric(id: "pending", label: "待处理", value: "\(pendingTotal)", systemImage: "clock.arrow.circlepath", tone: pendingTotal > 0 ? .warning : .neutral)
                ]
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(220))
                    self?.publishSyncResult(
                        title: hasUnfinishedWork ? "本次同步结束，仍有未完成文章" : "全部博主同步完成",
                        message: "已检查 \(creatorCount) 位博主，每位最多检查最近 \(articleLimit) 篇；共识别 \(checked) 篇 X Article。新增或补全保存 \(completed) 篇，已有完整归档跳过 \(skipped) 篇，需订阅 \(subscriptionRequired) 篇，失败 \(failed) 篇；保存或复用 \(images) 张图片、\(videos) 个视频。\n\n本次同步的 X API 调用为 0。\(failureNote)\(unaccountedNote)\(outstandingNote)",
                        metrics: metrics
                    )
                }
            } else {
                progress.stage = hasUnfinishedWork ? "本次队列结束，资料库仍有未完成文章" : "文章下载完成"
                statusMessage = hasUnfinishedWork
                    ? "本次队列结束：成功 \(completed) 篇，跳过 \(skipped) 篇，需订阅 \(subscriptionRequired) 篇，失败 \(failed) 篇；仍有未完成任务"
                    : "下载完成：成功 \(completed) 篇，跳过 \(skipped) 篇，失败 0 篇"
                let metrics = [
                    DownloadResultMetric(id: "queued", label: "进入队列", value: "\(total)", systemImage: "tray.and.arrow.down.fill", tone: .accent),
                    DownloadResultMetric(id: "saved", label: "成功保存", value: "\(completed)", systemImage: "checkmark.circle.fill", tone: .positive),
                    DownloadResultMetric(id: "skipped", label: "已跳过", value: "\(skipped)", systemImage: "forward.end.fill", tone: .neutral),
                    DownloadResultMetric(id: "subscription", label: "需订阅", value: "\(subscriptionRequired)", systemImage: "lock.fill", tone: subscriptionRequired > 0 ? .warning : .neutral),
                    DownloadResultMetric(id: "failed", label: "失败", value: "\(failed)", systemImage: "xmark.circle.fill", tone: failed > 0 ? .danger : .neutral),
                    DownloadResultMetric(id: "images", label: "图片", value: "\(images)", systemImage: "photo.fill", tone: .accent),
                    DownloadResultMetric(id: "videos", label: "视频", value: "\(videos)", systemImage: "video.fill", tone: .accent),
                    DownloadResultMetric(id: "pending", label: "待处理", value: "\(pendingTotal)", systemImage: "clock.arrow.circlepath", tone: pendingTotal > 0 ? .warning : .neutral)
                ]
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(220))
                    self?.downloadResultNotice = DownloadResultNotice(
                        title: hasUnfinishedWork ? "本次队列结束，仍有未完成文章" : "文章下载完成",
                        message: "本次进入下载队列 \(total) 篇，成功保存 \(completed) 篇，已有完整归档跳过 \(skipped) 篇，需订阅 \(subscriptionRequired) 篇，失败 \(failed) 篇；成功保存或复用 \(images) 张图片、\(videos) 个视频。\(failureNote)\(unaccountedNote)\(outstandingNote)",
                        metrics: metrics
                    )
                }
            }
        }
    }

    func browserCaptureState(for request: BrowserCaptureRequest) -> BackgroundDownloadItemState {
        if browserCaptureSubscriptionPostIDs.contains(request.link.postID) { return .subscriptionRequired }
        if browserCaptureFailurePostIDs.contains(request.link.postID) { return .failed }
        if browserCaptureSavedPostIDs.contains(request.link.postID) { return .saved }
        guard let index = browserCaptureRequests.firstIndex(where: { $0.id == request.id }) else {
            return .queued
        }
        if index == browserCaptureIndex { return .running }
        return .queued
    }

    func isPendingExactCaptureRequest(_ request: BrowserCaptureRequest) -> Bool {
        guard let article = articles.first(where: { $0.sourcePostID == request.link.postID }) else {
            return false
        }
        return ExactCaptureQueuePolicy.needsCapture(article)
    }

    func recordBrowserCaptureFailure(_ error: Error, request: BrowserCaptureRequest) async {
        let requiresSubscription = (error as? BrowserArticleCaptureError)?.requiresSubscription == true
        let isNewFailure = browserCaptureFailurePostIDs.insert(request.link.postID).inserted
        if requiresSubscription {
            browserCaptureSubscriptionPostIDs.insert(request.link.postID)
        } else {
            browserCaptureSubscriptionPostIDs.remove(request.link.postID)
        }
        progress.failedArticles = max(
            0,
            browserCaptureFailurePostIDs.count - browserCaptureSubscriptionPostIDs.count
        )
        if isNewFailure {
            browserCaptureFailureDetails.append("《\(request.displayTitle)》：\(error.localizedDescription)")
        }
        if let database,
           var failed = try? await database.article(sourcePostID: request.link.postID) {
            failed.pipelineState = requiresSubscription ? .subscriptionRequired : .failed
            failed.lastError = error.localizedDescription
            failed.lastSyncedAt = Date()
            failed.warnings.removeAll { $0 == ExactCaptureQueuePolicy.dismissedWarning }
            failed.appendProcessingLog(
                requiresSubscription
                    ? "检测到订阅访问限制：\(error.localizedDescription)"
                    : "处理失败：\(error.localizedDescription)"
            )
            try? await database.upsertArticle(failed)
            try? await reload()
        }
        statusMessage = requiresSubscription
            ? "《\(request.displayTitle)》需要订阅，已保留任务并继续下一篇"
            : "《\(request.displayTitle)》未完成，正在继续下一篇"
    }

    func closeBrowserCapture() {
        let stoppedRequest = currentBrowserCaptureRequest
        browserCaptureStopRequested = true
        showingBrowserCapture = false
        browserCaptureRequests = []
        browserCaptureIndex = 0
        finishDownloadProgressWindow()
        statusMessage = isSyncingTrackedCreators
            ? "已停止同步；已完成归档保留，未完成任务可继续"
            : "已停止精确排版采集；未完成任务已保留"
        guard let stoppedRequest, let database else { return }
        Task {
            if var stopped = try? await database.article(sourcePostID: stoppedRequest.link.postID) {
                stopped.pipelineState = .cancelled
                stopped.lastError = nil
                stopped.lastSyncedAt = Date()
                stopped.appendProcessingLog("用户停止处理；已完成步骤和本地媒体均保留")
                try? await database.upsertArticle(stopped)
                try? await reload()
            }
        }
    }

    func archiveBrowserCapture(
        _ payload: BrowserArticleCapturePayload,
        request: BrowserCaptureRequest
    ) async -> BrowserCaptureArchiveOutcome {
        guard !browserCaptureStopRequested else { return .stopped }
        guard let archiveRoot, let database else {
            await recordBrowserCaptureFailure(
                BrowserArticleCaptureError.pageNotReady("归档目录或资料库尚未就绪，未写入本地文件"),
                request: request
            )
            return .failed
        }
        isRunning = true
        errorMessage = nil
        progress.stage = "正在校验页面原始排版"
        defer { isRunning = false }

        do {
            if var restarting = try await database.article(sourcePostID: request.link.postID) {
                restarting.pipelineState = .parsed
                restarting.lastError = nil
                restarting.lastSyncedAt = Date()
                restarting.appendProcessingLog("X 页面读取完成，开始保存正文和媒体")
                try await database.upsertArticle(restarting)
            }
            let imageHost = try await configuredImageHost()
            let capturedHandle = HandleParser.normalize(payload.authorHandle ?? "")
                ?? request.creator.username
            let capturedName = payload.authorName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var creator: Creator
            if let exactCreator = try await database.creator(username: capturedHandle) {
                creator = exactCreator
            } else if capturedHandle.caseInsensitiveCompare(request.creator.username) == .orderedSame {
                creator = try await database.creator(username: request.creator.username) ?? request.creator
            } else if request.creator.xUserID.hasPrefix("browser:") {
                // X accepts status URLs whose username segment is stale or
                // simply wrong. Preserve the row UUID but replace that URL
                // hint with the author rendered on the verified Article page.
                creator = request.creator
                creator.xUserID = "browser:\(capturedHandle.lowercased())"
                creator.username = capturedHandle
                creator.displayName = capturedName.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "@\(capturedHandle)"
                creator.isEnabled = true
                try await database.updateCreatorIdentity(creator)
            } else {
                creator = Creator(
                    xUserID: "browser:\(capturedHandle.lowercased())",
                    username: capturedHandle,
                    displayName: capturedName.flatMap { $0.isEmpty ? nil : $0 }
                        ?? "@\(capturedHandle)"
                )
                try await database.upsertCreator(creator)
            }
            if let capturedName, !capturedName.isEmpty, creator.displayName != capturedName {
                creator.displayName = capturedName
                try await database.upsertCreator(creator)
            }
            let canonicalURL = URL(
                string: "https://x.com/\(creator.username)/status/\(request.link.postID)"
            )!
            let resolvedLink = XArticleLink(
                postID: request.link.postID,
                username: creator.username,
                originalURL: canonicalURL
            )
            let context = BrowserArticleCaptureContext(
                link: resolvedLink,
                creator: creator,
                publishedAt: request.publishedAt,
                sourceArticleID: request.sourceArticleID,
                expectedPlainText: request.expectedPlainText
            )
            let document = try BrowserArticleCaptureDecoder.decode(payload, context: context)
            let pipeline = ArchivePipeline(database: database, imageHost: imageHost)
            let archived = try await pipeline.archive(
                document: document,
                creator: creator,
                root: archiveRoot
            ) { [weak self] stage in
                await MainActor.run {
                    self?.progress.stage = stage
                    self?.statusMessage = stage
                }
            }
            progress.completedArticles += 1
            browserCaptureSavedPostIDs.insert(request.link.postID)
            progress.uploadedImages += document.media.count
            progress.uploadedVideos += document.videos?.count ?? 0
            browserCaptureFailurePostIDs.remove(request.link.postID)
            browserCaptureSubscriptionPostIDs.remove(request.link.postID)
            progress.failedArticles = max(
                0,
                browserCaptureFailurePostIDs.count - browserCaptureSubscriptionPostIDs.count
            )
            try await reload()
            selectedArticleID = archived.id
            statusMessage = "已保存完整排版：\(document.title)"
            return .saved
        } catch is CancellationError {
            statusMessage = "已停止精确排版采集；未完成任务已保留"
            return .stopped
        } catch {
            await recordBrowserCaptureFailure(error, request: request)
            return .failed
        }
    }

    func cancelCurrentTask() {
        if showingBrowserCapture {
            closeBrowserCapture()
            return
        }
        if showingCreatorArticleDiscovery {
            closeCreatorArticleDiscovery()
            return
        }
        runningTask?.cancel()
        statusMessage = "正在安全停止…"
    }

    func isArticleActivelyProcessing(_ article: ArchivedArticle) -> Bool {
        showingBrowserCapture && currentBrowserCaptureRequest?.link.postID == article.sourcePostID
    }

    func restartProcessing(_ article: ArchivedArticle) {
        guard !isRunning else { return }
        selectedArticleID = article.id
        captureSelectedArticleExactly()
    }

    func stopProcessing(_ article: ArchivedArticle) {
        guard isArticleActivelyProcessing(article) else { return }
        closeBrowserCapture()
    }

    func requestDeleteArticle(_ article: ArchivedArticle) {
        guard !isRunning else { return }
        articlePendingDeletion = article
    }

    func deletePendingArticle() {
        guard !isRunning,
              let article = articlePendingDeletion,
              let archiveRoot,
              let database else { return }
        articlePendingDeletion = nil

        Task {
            do {
                if let markdownPath = article.markdownPath {
                    let markdownURL = URL(fileURLWithPath: markdownPath)
                    guard Self.isContained(markdownURL, in: archiveRoot) else {
                        throw ArticleDeletionError.outsideArchiveRoot(markdownPath)
                    }
                    if FileManager.default.fileExists(atPath: markdownURL.path) {
                        try FileManager.default.trashItem(at: markdownURL, resultingItemURL: nil)
                    }
                }

                let snapshotURL = archiveRoot
                    .appending(path: ".x-article-archiver", directoryHint: .isDirectory)
                    .appending(path: "source-snapshots", directoryHint: .isDirectory)
                    .appending(path: "\(article.stableSourceKey).json")
                guard Self.isContained(snapshotURL, in: archiveRoot) else {
                    throw ArticleDeletionError.outsideArchiveRoot(snapshotURL.path)
                }
                if FileManager.default.fileExists(atPath: snapshotURL.path) {
                    try FileManager.default.trashItem(at: snapshotURL, resultingItemURL: nil)
                }

                try await database.deleteArticle(id: article.id)
                if let creator = creators.first(where: { $0.id == article.creatorID }) {
                    try ArchiveIndexWriter.rebuild(root: archiveRoot, creator: creator)
                }
                if selectedArticleID == article.id { selectedArticleID = nil }
                try await reload()
                statusMessage = "已将《\(article.title)》移到废纸篓；远程图片和视频未删除"
            } catch {
                // If deleting the database row succeeded but refreshing an
                // index failed, do not leave a stale in-memory ghost article.
                try? await reload()
                errorMessage = error.localizedDescription
                statusMessage = "删除文章失败"
            }
        }
    }

    func requestDeleteExactCaptureTask(_ article: ArchivedArticle) {
        guard ExactCaptureQueuePolicy.needsCapture(article) else { return }
        stopBrowserCaptureBeforeConfirmation {
            self.exactCaptureTaskPendingDeletion = article
        }
    }

    func requestDeleteExactCaptureTask(_ request: BrowserCaptureRequest) {
        guard let article = articles.first(where: { $0.sourcePostID == request.link.postID }) else {
            closeBrowserCapture()
            statusMessage = "该临时任务未写入资料库，已从本次队列移除"
            return
        }
        requestDeleteExactCaptureTask(article)
    }

    func requestDeleteAllExactCaptureTasks() {
        guard pendingExactCaptureCount > 0 else { return }
        stopBrowserCaptureBeforeConfirmation {
            self.showingDeleteAllExactCaptureTasksConfirmation = true
        }
    }

    func deletePendingExactCaptureTask() {
        guard !isRunning,
              let article = exactCaptureTaskPendingDeletion,
              let database else { return }
        exactCaptureTaskPendingDeletion = nil

        Task {
            do {
                let preserved = try await discardExactCaptureTask(article, database: database)
                if selectedArticleID == article.id, !preserved { selectedArticleID = nil }
                try await reload()
                statusMessage = preserved
                    ? "已删除《\(article.title)》的精确采集任务；原有归档保留"
                    : "已删除《\(article.title)》的未完成采集任务"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "删除精确采集任务失败"
            }
        }
    }

    func deleteAllPendingExactCaptureTasks() {
        guard !isRunning, let database else { return }
        showingDeleteAllExactCaptureTasksConfirmation = false
        let tasks = pendingExactCaptureArticles

        Task {
            do {
                var preservedCount = 0
                var removedCount = 0
                var removedIDs = Set<UUID>()
                for article in tasks {
                    if try await discardExactCaptureTask(article, database: database) {
                        preservedCount += 1
                    } else {
                        removedCount += 1
                        removedIDs.insert(article.id)
                    }
                }
                if let selectedArticleID, removedIDs.contains(selectedArticleID) {
                    self.selectedArticleID = nil
                }
                try await reload()
                statusMessage = "已删除 \(tasks.count) 个精确采集任务：清理 \(removedCount) 条未完成记录，保留 \(preservedCount) 篇原有归档"
            } catch {
                try? await reload()
                errorMessage = error.localizedDescription
                statusMessage = "批量删除精确采集任务失败"
            }
        }
    }

    func requestDeleteCreator(_ creator: Creator) {
        guard !isRunning else { return }
        creatorPendingDeletion = creator
    }

    func deletePendingCreator() {
        guard !isRunning,
              let creator = creatorPendingDeletion,
              let database else { return }
        creatorPendingDeletion = nil

        Task {
            do {
                try await database.setCreatorEnabled(id: creator.id, isEnabled: false)
                if sidebarSelection == .creator(creator.id) {
                    sidebarSelection = .all
                }
                try await reload()
                statusMessage = "已删除博主 @\(creator.username)；已经下载的文章和图片均已保留"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "删除博主失败"
            }
        }
    }

    func installDemo() {
        guard let archiveRoot, let database else {
            errorMessage = "请先选择本地归档目录"
            showingConnectionSetup = true
            return
        }
        runningTask = Task {
            isRunning = true
            defer { isRunning = false }
            do {
                let oldDemo = try await database.creator(xUserID: "demo-user")
                let creator = Creator(
                    id: oldDemo?.id ?? UUID(),
                    xUserID: "demo-user",
                    username: "demo_author",
                    displayName: "体验作者",
                    isEnabled: true,
                    lastSyncAt: oldDemo?.lastSyncAt,
                    lastSeenPostID: oldDemo?.lastSeenPostID,
                    completeness: .recentWindowComplete
                )
                try await database.upsertCreator(creator)
                let source = URL(string: "https://x.com/demo_author/status/1900000000000000000")!
                let document = CanonicalDocument(
                    title: "这是一篇可以落到本地的 X 长文",
                    authorName: creator.displayName,
                    authorHandle: creator.username,
                    contentType: .xArticle,
                    sourceURL: source,
                    sourcePostID: "1900000000000000000",
                    sourceArticleID: "demo-article-001",
                    publishedAt: Date(),
                    blocks: [
                        CanonicalBlock(kind: .paragraph, text: "这不是空白界面。体验样例会实际生成一份 Markdown、作者索引和 SQLite 记录。"),
                        CanonicalBlock(kind: .heading, text: "保留结构", level: 1),
                        CanonicalBlock(kind: .paragraph, text: "正式归档时，正文不会交给 AI，也不会被改写。"),
                        CanonicalBlock(kind: .unorderedListItem, text: "标题和段落保持原顺序"),
                        CanonicalBlock(kind: .unorderedListItem, text: "图片先缓存、再上传、最后写入 Markdown"),
                        CanonicalBlock(kind: .quote, text: "图片没有全部验证成功，文章就不会显示完成。"),
                    ],
                    sourceMediaIDs: [],
                    layoutFidelity: .exactStructure
                )
                let pipeline = ArchivePipeline(
                    database: database,
                    imageHost: LocalMediaHostAdapter(archiveRoot: archiveRoot)
                )
                _ = try await pipeline.archive(document: document, creator: creator, root: archiveRoot) { [weak self] stage in
                    await MainActor.run { self?.statusMessage = stage }
                }
                try await reload()
                selectedArticleID = articles.first(where: { $0.sourceArticleID == "demo-article-001" })?.id
                statusMessage = "体验样例已经真实写入归档目录"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "体验样例生成失败"
            }
        }
    }

    func openSelectedArticle() {
        guard let path = selectedArticle?.markdownPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func revealSelectedArticle() {
        guard let path = selectedArticle?.markdownPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openSource() {
        guard let article = selectedArticle else { return }
        let sourceURL = XArticleNavigationURL.articleURL(
            authorHandle: article.authorHandle,
            postID: article.sourcePostID
        ) ?? article.sourceURL
        if article.pipelineState == .subscriptionRequired {
            openInChrome(
                sourceURL,
                successMessage: "已在 Chrome 打开《\(article.title)》原文"
            )
        } else {
            NSWorkspace.shared.open(sourceURL)
        }
    }

    func openSubscriptionPage(for article: ArchivedArticle) {
        guard let handle = HandleParser.normalize(article.authorHandle),
              let subscriptionURL = XArticleNavigationURL.subscriptionURL(
                authorHandle: handle
              ) else { return }
        openInChrome(
            subscriptionURL,
            successMessage: "已在 Chrome 打开 @\(handle) 的订阅页面"
        )
    }

    private func openInChrome(_ url: URL, successMessage: String) {
        guard let chromeURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.google.Chrome"
        ) else {
            NSWorkspace.shared.open(url)
            statusMessage = "未检测到 Google Chrome，已在默认浏览器打开"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: chromeURL,
            configuration: configuration,
            completionHandler: nil
        )
        statusMessage = successMessage
    }

    func openCreatorProfile(_ creator: Creator) {
        openCreatorProfile(handle: creator.username)
    }

    func openCreatorProfile(handle: String) {
        guard let normalized = HandleParser.normalize(handle),
              let profileURL = URL(string: "https://x.com/\(normalized)") else { return }
        NSWorkspace.shared.open(profileURL)
    }

    func markdownPreview(for article: ArchivedArticle?) -> String {
        guard let path = article?.markdownPath else { return "" }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? "无法读取本地 Markdown。"
    }

    func previewDocument(for article: ArchivedArticle?) -> CanonicalDocument? {
        guard let article, let archiveRoot else { return nil }
        let snapshotURL = archiveRoot
            .appending(path: ".x-article-archiver", directoryHint: .isDirectory)
            .appending(path: "source-snapshots", directoryHint: .isDirectory)
            .appending(path: "\(article.stableSourceKey).json")
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var document = try? decoder.decode(CanonicalDocument.self, from: data) else { return nil }
        for index in document.media.indices {
            document.media[index].localCachePath = Self.previewLocalMediaPath(
                document.media[index].localCachePath,
                root: archiveRoot
            )
            document.media[index].remoteURL = Self.previewMediaURL(
                document.media[index].remoteURL,
                root: archiveRoot
            )
        }
        if document.videos != nil {
            for index in document.videos!.indices {
                document.videos![index].localCachePath = Self.previewLocalMediaPath(
                    document.videos![index].localCachePath,
                    root: archiveRoot
                )
                document.videos![index].remoteURL = Self.previewMediaURL(
                    document.videos![index].remoteURL,
                    root: archiveRoot
                )
            }
        }
        let visibleBlocks = document.blocks.filter { $0.kind != .image && $0.kind != .divider }
        if visibleBlocks.count == 1 {
            let text = visibleBlocks[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("https://t.co/") { return nil }
        }
        return document
    }

    private static func previewMediaURL(_ storedURL: URL?, root: URL) -> URL? {
        guard let storedURL else { return nil }
        if storedURL.scheme != nil { return storedURL }
        let relativePath = storedURL.relativeString.removingPercentEncoding ?? storedURL.relativeString
        let components = NSString(string: relativePath).pathComponents
        guard relativePath.hasPrefix("media/"),
              !relativePath.hasPrefix("/"),
              !components.contains("..") else { return nil }
        let resolved = root.appending(path: relativePath).standardizedFileURL
        guard isContained(resolved, in: root) else { return nil }
        return resolved
    }

    private static func previewLocalMediaPath(_ storedPath: String?, root: URL) -> String? {
        guard let storedPath else { return nil }
        let storedURL = URL(fileURLWithPath: storedPath).standardizedFileURL
        if FileManager.default.fileExists(atPath: storedURL.path) { return storedURL.path }
        for marker in ["/media/", "/.x-article-archiver/"] {
            guard let range = storedURL.path.range(of: marker) else { continue }
            let relative = String(storedURL.path[range.lowerBound...]).dropFirst()
            let rebased = root.appending(path: String(relative)).standardizedFileURL
            guard isContained(rebased, in: root), FileManager.default.fileExists(atPath: rebased.path) else {
                continue
            }
            return rebased.path
        }
        return nil
    }

    private func prepareDirectBrowserCapture(
        links: [XArticleLink],
        refreshExisting: Bool,
        preferredTitles: [String: String] = [:]
    ) {
        guard !links.isEmpty, !isRunning else { return }
        guard let archiveRoot, let database else {
            errorMessage = "归档目录尚未准备好"
            return
        }

        runningTask = Task {
            isRunning = true
            errorMessage = nil
            progress = SyncProgress(stage: "正在建立本地采集队列")
            defer {
                isRunning = false
                runningTask = nil
            }
            do {
                var requests: [BrowserCaptureRequest] = []
                var localHits = 0
                for link in links {
                    if !refreshExisting,
                       let existing = try await database.article(sourcePostID: link.postID),
                       Self.hasExactValidatedLocalArchive(existing, root: archiveRoot) {
                        localHits += 1
                        continue
                    }

                    var creator = try await database.creator(username: link.username)
                        ?? Creator(
                            xUserID: "browser:\(link.username.lowercased())",
                            username: link.username,
                            displayName: "@\(link.username)"
                        )
                    creator.isEnabled = true
                    try await database.upsertCreator(creator)
                    let existing = try await database.article(sourcePostID: link.postID)
                    let title = existing?.title
                        ?? preferredTitles[link.postID]
                        ?? "待读取的 X Article · \(link.postID.suffix(8))"
                    let sourcePublishedAt = XArticleURLParser.publishedAt(forPostID: link.postID)
                    try await savePendingReferenceIfNeeded(
                        link: link,
                        creator: creator,
                        title: title,
                        publishedAt: sourcePublishedAt ?? existing?.publishedAt ?? Date(),
                        sourceArticleID: existing?.sourceArticleID,
                        database: database
                    )
                    requests.append(BrowserCaptureRequest(
                        link: link,
                        creator: creator,
                        displayTitle: title,
                        publishedAt: sourcePublishedAt ?? existing?.publishedAt,
                        sourceArticleID: existing?.sourceArticleID
                    ))
                }
                try await reload()
                progress.discoveredArticles = links.count
                progress.skippedArticles = localHits
                guard !requests.isEmpty else {
                    finishDownloadProgressWindow()
                    if let creatorCount = activeSyncCreatorCount,
                       let articleLimit = activeSyncArticleLimit {
                        progress.stage = "全部博主同步完成"
                        statusMessage = "同步完成：\(localHits) 篇已有完整归档，全部跳过"
                        publishSyncResult(
                            title: "全部博主已经是最新状态",
                            message: "已检查 \(creatorCount) 位博主，每位最多检查最近 \(articleLimit) 篇；识别到的 \(localHits) 篇 X Article 都已经完整归档，因此全部跳过，没有重复下载或存储媒体。\n\n本次 X API 调用为 0。",
                            metrics: [
                                DownloadResultMetric(id: "creators", label: "博主", value: "\(creatorCount)", systemImage: "person.2.fill", tone: .accent),
                                DownloadResultMetric(id: "checked", label: "检查文章", value: "\(localHits)", systemImage: "doc.text.magnifyingglass", tone: .accent),
                                DownloadResultMetric(id: "saved", label: "新增保存", value: "0", systemImage: "checkmark.circle.fill", tone: .positive),
                                DownloadResultMetric(id: "skipped", label: "已跳过", value: "\(localHits)", systemImage: "forward.end.fill", tone: .neutral)
                            ]
                        )
                    } else {
                        progress.stage = "全部链接已精确保存"
                        statusMessage = "\(localHits) 篇文章已有完整排版；本次 X API 调用为 0"
                        downloadResultNotice = DownloadResultNotice(
                            title: "不需要重复下载",
                            message: "识别到的 \(localHits) 篇文章都已经完整保存在本地，本次没有重复下载或存储媒体。",
                            metrics: [
                                DownloadResultMetric(id: "checked", label: "检查文章", value: "\(localHits)", systemImage: "doc.text.magnifyingglass", tone: .accent),
                                DownloadResultMetric(id: "saved", label: "新增保存", value: "0", systemImage: "checkmark.circle.fill", tone: .positive),
                                DownloadResultMetric(id: "skipped", label: "已跳过", value: "\(localHits)", systemImage: "forward.end.fill", tone: .neutral)
                            ]
                        )
                    }
                    return
                }
                progress.stage = isSyncingTrackedCreators ? "正在后台同步新文章" : "等待精确排版采集"
                statusMessage = isSyncingTrackedCreators
                    ? "需要保存 \(requests.count) 篇，已同步跳过 \(localHits) 篇；X API 调用为 0"
                    : "已建立 \(requests.count) 篇采集队列；X API 调用为 0"
                beginBrowserCapture(requests, skippedCount: localHits)
            } catch {
                errorMessage = error.localizedDescription
                progress.stage = "无法建立采集队列"
                finishDownloadProgressWindow()
                if isSyncingTrackedCreators {
                    publishSyncResult(
                        title: "同步未完成",
                        message: "无法建立新文章采集队列：\(error.localizedDescription)",
                        metrics: [
                            DownloadResultMetric(id: "status", label: "同步状态", value: "未完成", systemImage: "exclamationmark.triangle.fill", tone: .danger),
                            DownloadResultMetric(id: "saved", label: "已保存", value: "\(progress.completedArticles)", systemImage: "checkmark.circle.fill", tone: .positive)
                        ]
                    )
                }
            }
        }
    }

    private func savePendingReferenceIfNeeded(
        link: XArticleLink,
        creator: Creator,
        title: String,
        publishedAt: Date,
        sourceArticleID: String?,
        database: ArchiveDatabase
    ) async throws {
        guard try await database.article(sourcePostID: link.postID) == nil else { return }
        let record = ArchivedArticle(
            stableSourceKey: sourceArticleID ?? link.postID,
            creatorID: creator.id,
            title: title,
            authorHandle: creator.username,
            contentType: .xArticle,
            sourceURL: URL(string: "https://x.com/\(link.username)/status/\(link.postID)")!,
            sourcePostID: link.postID,
            sourceArticleID: sourceArticleID,
            publishedAt: publishedAt,
            sourceChecksum: "pending-rendered-page-capture",
            pipelineState: .discovered,
            warnings: ["等待在应用内打开 X Article 并保存精确排版"],
            processingLog: ["\(ISO8601DateFormatter().string(from: Date()))  已建立文章处理任务"]
        )
        try await database.upsertArticle(record)
    }

    private func beginBrowserCapture(
        _ requests: [BrowserCaptureRequest],
        skippedCount: Int = 0
    ) {
        browserCaptureStopRequested = false
        var seen = Set<String>()
        browserCaptureRequests = requests.filter { seen.insert($0.link.postID).inserted }
        reactivateExactCaptureTasks(for: browserCaptureRequests)
        browserCaptureSavedPostIDs.removeAll()
        browserCaptureFailurePostIDs.removeAll()
        browserCaptureSubscriptionPostIDs.removeAll()
        browserCaptureFailureDetails.removeAll()
        progress.skippedArticles = skippedCount
        progress.completedArticles = 0
        progress.uploadedImages = 0
        progress.uploadedVideos = 0
        progress.failedArticles = 0
        progress.discoveredArticles = max(progress.discoveredArticles, browserCaptureRequests.count)
        browserCaptureIndex = 0
        showingBrowserCapture = !browserCaptureRequests.isEmpty
        presentDownloadProgressWindowIfAllowed()
    }

    private func reactivateExactCaptureTasks(for requests: [BrowserCaptureRequest]) {
        let postIDs = Set(requests.map(\.link.postID))
        var changed: [ArchivedArticle] = []
        for index in articles.indices where postIDs.contains(articles[index].sourcePostID) {
            articles[index].warnings.removeAll { $0 == ExactCaptureQueuePolicy.dismissedWarning }
            articles[index].pipelineState = .discovered
            articles[index].lastError = nil
            articles[index].lastSyncedAt = Date()
            articles[index].appendProcessingLog("重新开始处理")
            changed.append(articles[index])
        }
        guard !changed.isEmpty, let database else { return }
        Task {
            for article in changed {
                try? await database.upsertArticle(article)
            }
        }
    }

    private func stopBrowserCaptureBeforeConfirmation(_ action: @escaping @MainActor () -> Void) {
        if showingBrowserCapture || !browserCaptureRequests.isEmpty {
            closeBrowserCapture()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isRunning {
                try? await Task.sleep(for: .milliseconds(80))
            }
            try? await Task.sleep(for: .milliseconds(160))
            action()
        }
    }

    private func discardExactCaptureTask(
        _ article: ArchivedArticle,
        database: ArchiveDatabase
    ) async throws -> Bool {
        if let preserved = ExactCaptureQueuePolicy.articleAfterDismissingTask(article) {
            try await database.upsertArticle(preserved)
            return true
        }
        try await database.deleteArticle(id: article.id)
        return false
    }

    private static func hasExactValidatedLocalArchive(_ article: ArchivedArticle, root: URL) -> Bool {
        guard article.pipelineState == .committed,
              let markdownPath = article.markdownPath,
              let markdown = try? String(contentsOfFile: markdownPath, encoding: .utf8) else { return false }
        let snapshotURL = root
            .appending(path: ".x-article-archiver", directoryHint: .isDirectory)
            .appending(path: "source-snapshots", directoryHint: .isDirectory)
            .appending(path: "\(article.stableSourceKey).json")
        guard let data = try? Data(contentsOf: snapshotURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(CanonicalDocument.self, from: data),
              document.layoutFidelity == .renderedPageVerified || document.layoutFidelity == .exactStructure,
              (try? ContentFidelityValidator.validateCanonical(document)) != nil,
              (try? MarkdownRenderer.validateRenderedText(
                document: document,
                markdown: markdown,
                archiveRoot: root,
                markdownDirectory: URL(fileURLWithPath: markdownPath).deletingLastPathComponent()
              )) != nil else {
            return false
        }
        return true
    }

    private func configureDatabase(at root: URL) async {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let migration = try ArchiveLayout.migrateLegacyLayout(in: root)
            let openedDatabase = try ArchiveDatabase(url: Self.databaseURL(for: root))
            database = openedDatabase
            try await migrateArticlePathsAndRebuildIndexes(at: root, database: openedDatabase)
            try await reload()
            statusMessage = migration.didChange ? "已迁移旧目录，归档目录已就绪" : "归档目录已就绪"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func migrateArticlePathsAndRebuildIndexes(
        at root: URL,
        database: ArchiveDatabase
    ) async throws {
        let storedArticles = try await database.loadArticles()
        for var article in storedArticles {
            guard let currentPath = article.markdownPath,
                  let migratedPath = ArchiveLayout.migratedMarkdownPath(currentPath, in: root)
            else { continue }
            guard FileManager.default.fileExists(atPath: migratedPath) else {
                throw ArchiveLayoutError.invalidLegacyPath(migratedPath)
            }
            article.markdownPath = migratedPath
            try await database.upsertArticle(article)
        }
        for creator in try await database.loadCreators() {
            try ArchiveIndexWriter.rebuild(root: root, creator: creator)
        }
    }

    private func reload() async throws {
        guard let database else { return }
        creators = try await database.loadCreators().filter(\.isEnabled)
        reconcilePinnedCreatorIDs()
        // Older builds also stored Note Posts and assembled threads. Keep the
        // user's files and rows intact, but never present them as X Articles.
        var loadedArticles = try await database.loadArticles().filter { $0.contentType == .xArticle }
        // Builds before 18 could persist the discovery/archive timestamp for a
        // direct link. Correct every existing UI/database record from the X
        // Snowflake itself, without touching a possibly user-edited Markdown
        // file. A later automatic recapture safely rewrites and renames the
        // exported file through the normal checksum gate.
        for index in loadedArticles.indices {
            guard let sourceDate = XArticleURLParser.publishedAt(
                forPostID: loadedArticles[index].sourcePostID
            ), abs(loadedArticles[index].publishedAt.timeIntervalSince(sourceDate)) > 1 else { continue }
            loadedArticles[index].publishedAt = sourceDate
            try await database.upsertArticle(loadedArticles[index])
        }
        if let archiveRoot {
            Self.migrateGeneratedMarkdownFormattingIfSafe(loadedArticles, root: archiveRoot)
        }
        articles = loadedArticles.sorted { lhs, rhs in
            if lhs.publishedAt != rhs.publishedAt { return lhs.publishedAt > rhs.publishedAt }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        if case .creator(let creatorID) = sidebarSelection,
           !creators.contains(where: { $0.id == creatorID }) {
            sidebarSelection = .all
        }
        synchronizeSelectedArticleWithSidebar()
    }

    /// Re-renders only files that still carry a valid exporter checksum. This
    /// upgrades old generated list numbering and list/paragraph boundaries
    /// without ever overwriting a Markdown file the user edited by hand.
    private static func migrateGeneratedMarkdownFormattingIfSafe(
        _ articles: [ArchivedArticle],
        root: URL
    ) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshotRoot = root
            .appending(path: ".x-article-archiver", directoryHint: .isDirectory)
            .appending(path: "source-snapshots", directoryHint: .isDirectory)

        for article in articles {
            guard let markdownPath = article.markdownPath else { continue }
            let markdownURL = URL(fileURLWithPath: markdownPath)
            guard isContained(markdownURL, in: root),
                  let current = try? String(contentsOf: markdownURL, encoding: .utf8),
                  MarkdownRenderer.isUnmodifiedExport(current),
                  let snapshotData = try? Data(
                    contentsOf: snapshotRoot.appending(path: "\(article.stableSourceKey).json")
                  ),
                  let document = try? decoder.decode(CanonicalDocument.self, from: snapshotData),
                  document.sourcePostID == article.sourcePostID,
                  document.title == article.title,
                  document.sourceURL == article.sourceURL,
                  (try? ContentFidelityValidator.validateCanonical(document)) != nil,
                  let rendered = try? MarkdownRenderer.render(
                    document: document,
                    archivedAt: article.archivedAt,
                    archiveRoot: root,
                    markdownDirectory: markdownURL.deletingLastPathComponent()
                  ),
                  (try? MarkdownRenderer.validateRenderedText(
                    document: document,
                    markdown: rendered,
                    archiveRoot: root,
                    markdownDirectory: markdownURL.deletingLastPathComponent()
                  )) != nil else {
                continue
            }
            let upgraded = MarkdownRenderer.addingExportChecksum(to: rendered)
            guard upgraded != current else { continue }
            try? Data(upgraded.utf8).write(to: markdownURL, options: .atomic)
        }
    }

    private static func databaseURL(for root: URL) -> URL {
        root.appending(path: ".x-article-archiver/archive.sqlite")
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func configuredImageHost() async throws -> any ImageHostAdapter {
        switch imageHostChoice {
        case .local:
            guard let archiveRoot else {
                throw ImagePipelineError.hostUnavailable("请先选择本地归档目录")
            }
            return LocalMediaHostAdapter(archiveRoot: archiveRoot)
        case .uPic:
            guard let archiveRoot else {
                throw ImagePipelineError.hostUnavailable("请先选择本地归档目录")
            }
            let adapter = UPicAdapter()
            let capability = await adapter.probe()
            guard capability.isAvailable else {
                setImageHostVerified(false)
                throw ImagePipelineError.hostUnavailable(capability.detail)
            }
            return MirroredMediaHostAdapter(primary: adapter, archiveRoot: archiveRoot)
        case .s3:
            let credentials = try await Task.detached(priority: .userInitiated) {
                (
                    access: try KeychainStore.read(account: KeychainStore.s3AccessKeyAccount),
                    secret: try KeychainStore.read(account: KeychainStore.s3SecretKeyAccount)
                )
            }.value
            guard let endpoint = URL(string: s3Endpoint), let publicBase = URL(string: s3PublicBaseURL),
                  let access = credentials.access,
                  let secret = credentials.secret else {
                throw S3ImageHostError.invalidConfiguration("缺少 S3/R2 配置或钥匙串凭证")
            }
            let configuration = S3ImageHostConfiguration(endpoint: endpoint, bucket: s3Bucket, publicBaseURL: publicBase, region: s3Region, keyPrefix: s3KeyPrefix)
            return S3ImageHostAdapter(configuration: configuration, accessKey: access, secretKey: secret)
        }
    }

    private func setImageHostVerified(_ value: Bool) {
        imageHostVerified = value
        defaults.set(value, forKey: "imageHostVerified")
    }

    private func uploadSyntheticTestImage(
        using adapter: any ImageHostAdapter,
        stagingRoot: URL = FileManager.default.temporaryDirectory
    ) async throws -> URL {
        let directory = stagingRoot.appending(
            path: "x-article-archiver-host-test-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "连接测试.png")
        try Self.testPNGData.write(to: file, options: .atomic)
        let results = try await adapter.upload(fileURLs: [file])
        guard let remote = results.first?.remoteURL else { throw ImagePipelineError.invalidOutput("没有返回 URL") }
        try await adapter.verify(remoteURL: remote)
        return remote
    }

    private static let testPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}
