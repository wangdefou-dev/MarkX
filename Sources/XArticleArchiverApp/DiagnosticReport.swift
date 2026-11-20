import AppKit
import XArticleArchiverCore

struct DiagnosticDatabaseSnapshot {
    var databasePath: String?
    var journalMode: String?
    var location: StorageLocationInfo?
    var problemArticles: [ArchivedArticle]
    var loadError: String?
}

/// Builds a zip a user can send when something goes wrong: recent logs,
/// system and app facts, library statistics, the processing history of
/// unfinished articles and recent crash reports. It never contains X
/// session data, storage credentials or article bodies, and nothing is
/// uploaded: the user decides where the file goes.
@MainActor
enum DiagnosticReport {
    static let issuesURL = URL(string: "https://github.com/wangdefou-dev/MarkX/issues/new")!

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版本"
    }

    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    static var systemLine: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)（\(ProcessInfo.processInfo.operatingSystemVersionString)），\(hardwareModel)，\(architecture)"
    }

    /// Writes one line when the app starts, so every log begins with context.
    static func logLaunch() {
        let memory = ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
        MarkXLog.info("app", "MarkX \(appVersion)（\(appBuild)）启动；\(systemLine)，内存 \(memory)；语言 \(Locale.preferredLanguages.first ?? "—")；路径 \(Bundle.main.bundlePath)")
    }

    /// Asks where to save, writes the report and shows it in Finder.
    /// Returns the zip URL, or nil when the user cancelled or it failed.
    @discardableResult
    static func export(model: AppViewModel) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出诊断报告"
        panel.message = "报告包含应用日志、系统信息、资料库统计、未完成文章的处理记录和崩溃记录；不含 X 登录信息、图床密钥和文章正文。"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = "MarkX-诊断报告-\(fileTimestamp()).zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }

        MarkXLog.info("diagnostics", "开始导出诊断报告到 \(destination.path)")
        let snapshot = await model.diagnosticDatabaseSnapshot()
        let summary = summaryText(model: model, snapshot: snapshot)
        let problems = problemArticlesText(snapshot.problemArticles)
        do {
            try await Task.detached(priority: .userInitiated) {
                try writeReport(summary: summary, problems: problems, to: destination)
            }.value
            MarkXLog.info("diagnostics", "诊断报告已导出")
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return destination
        } catch {
            MarkXLog.error("diagnostics", "导出诊断报告失败：\(error.localizedDescription)")
            model.errorMessage = "导出诊断报告失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// Exports the report, then opens a pre-filled GitHub issue to attach it to.
    static func reportProblem(model: AppViewModel) async {
        guard let report = await export(model: model) else { return }
        let body = """
        **问题描述**
        （发生了什么？期望是什么？）

        **复现步骤**
        1.

        **环境**
        - MarkX \(appVersion)（\(appBuild)）
        - \(systemLine)

        请把桌面上导出的诊断报告「\(report.lastPathComponent)」拖到这里一起提交。
        """
        var components = URLComponents(url: issuesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "title", value: "[MarkX \(appVersion)] "),
            URLQueryItem(name: "body", value: body)
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    static func revealLogs() {
        MarkXLog.flush()
        let current = MarkXLog.currentFileURL
        if FileManager.default.fileExists(atPath: current.path) {
            NSWorkspace.shared.activateFileViewerSelecting([current])
        } else {
            try? FileManager.default.createDirectory(at: MarkXLog.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(MarkXLog.directory)
        }
    }

    // MARK: - Content

    private static func summaryText(model: AppViewModel, snapshot: DiagnosticDatabaseSnapshot) -> String {
        var lines: [String] = []
        func add(_ key: String, _ value: String) { lines.append("\(key)：\(value)") }
        lines.append("MarkX 诊断报告")
        lines.append("生成时间：\(Date().formatted(date: .complete, time: .standard))")
        lines.append("")
        lines.append("【应用与系统】")
        add("版本", "\(appVersion)（Build \(appBuild)）")
        add("安装路径", Bundle.main.bundlePath)
        add("系统", systemLine)
        add("内存", ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
        add("语言 / 地区", "\(Locale.preferredLanguages.joined(separator: ", ")) / \(Locale.current.identifier)，时区 \(TimeZone.current.identifier)")
        add("运行时长", "\(Int(ProcessInfo.processInfo.systemUptime / 3600)) 小时（系统）")
        lines.append("")
        lines.append("【资料库】")
        if let root = model.archiveRoot {
            add("归档目录", root.path)
            add("目录所在磁盘", (snapshot.location ?? StorageLocationInfo.inspect(root)).summary)
        } else {
            add("归档目录", "尚未选择")
        }
        add("数据库", snapshot.databasePath ?? "未打开")
        add("日志模式", snapshot.journalMode ?? "—")
        if let path = snapshot.databasePath {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let file = path + suffix
                if let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.int64Value {
                    add("  \(URL(fileURLWithPath: file).lastPathComponent)", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            }
        }
        if let loadError = snapshot.loadError { add("读取数据库出错", loadError) }
        add("博主", "\(model.creators.count) 位（启用 \(model.enabledCreatorCount) 位）")
        add("文章", "\(model.articles.count) 篇")
        let states = Dictionary(grouping: model.articles, by: \.pipelineState)
            .map { "\($0.key.displayName) \($0.value.count)" }
            .sorted()
        if !states.isEmpty { add("文章状态", states.joined(separator: "，")) }
        add("待精确采集", "\(model.pendingExactCaptureCount) 篇")
        lines.append("")
        lines.append("【连接与存储】")
        add("首选浏览器", model.preferredBrowserID)
        add("检测到 X 登录", model.hasBrowserSessionData ? "是" : "否")
        add("媒体存储", "\(model.imageHostChoice)（已验证：\(model.imageHostVerified ? "是" : "否")）")
        add("uPic", model.upicCapability.detail)
        lines.append("")
        lines.append("【当前状态】")
        add("任务进行中", model.isRunning ? "是" : "否")
        add("状态", model.statusMessage)
        add("进度阶段", model.progress.stage)
        if let error = model.errorMessage { add("当前错误", error) }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func problemArticlesText(_ articles: [ArchivedArticle]) -> String {
        guard !articles.isEmpty else { return "没有未完成或出错的文章。\n" }
        var lines = ["未完成或出错的文章（最近 \(articles.count) 篇）", ""]
        for article in articles {
            lines.append("— \(article.title)")
            lines.append("  来源：\(article.sourceURL.absoluteString)")
            lines.append("  状态：\(article.pipelineState.displayName)；最后同步：\(article.lastSyncedAt.formatted(date: .numeric, time: .standard))")
            if let error = article.lastError { lines.append("  错误：\(error)") }
            for entry in article.processingLog.suffix(30) { lines.append("    \(entry)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Files

    nonisolated private static func writeReport(summary: String, problems: String, to destination: URL) throws {
        MarkXLog.flush()
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: "markx-diagnostics-\(UUID())", directoryHint: .isDirectory)
        let folder = staging.appending(path: destination.deletingPathExtension().lastPathComponent, directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try summary.write(to: folder.appending(path: "概要.txt"), atomically: true, encoding: .utf8)
        try problems.write(to: folder.appending(path: "未完成文章.txt"), atomically: true, encoding: .utf8)

        let logs = folder.appending(path: "logs", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        for file in MarkXLog.allFileURLs {
            try? fileManager.copyItem(at: file, to: logs.appending(path: file.lastPathComponent))
        }

        let crashes = recentCrashReports()
        if !crashes.isEmpty {
            let crashFolder = folder.appending(path: "crashes", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: crashFolder, withIntermediateDirectories: true)
            for file in crashes {
                try? fileManager.copyItem(at: file, to: crashFolder.appending(path: file.lastPathComponent))
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "压缩诊断报告失败（ditto \(process.terminationStatus)）"])
        }
    }

    /// Crash and hang reports for MarkX from the last 30 days.
    nonisolated static func recentCrashReports(now: Date = Date()) -> [URL] {
        let fileManager = FileManager.default
        let folders = [
            fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Logs/DiagnosticReports"),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
        ]
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
        return folders.flatMap { folder -> [URL] in
            let items = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            return items.filter { url in
                let name = url.lastPathComponent
                guard name.hasPrefix("XArticleArchiverApp") || name.hasPrefix("MarkX") else { return false }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return date >= cutoff
            }
        }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
        .prefix(20)
        .map { $0 }
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "未知机型" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
