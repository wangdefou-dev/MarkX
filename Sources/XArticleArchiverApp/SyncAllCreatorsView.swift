import SwiftUI

enum SyncVisualStyle {
    static let symbolName = "arrow.clockwise"
    static let iconSize: CGFloat = 14
}

struct SyncAllCreatorsView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case now
        case schedule

        var id: String { rawValue }
        var title: String { self == .now ? "立即同步" : "定时同步" }
        var symbol: String { self == .now ? SyncVisualStyle.symbolName : "clock" }
    }

    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .now
    @State private var articleLimit = 10
    @State private var downloadAllArticles = false
    @State private var resolveTotalCount = false
    @State private var scheduleEnabled = false
    @State private var scheduleTime = Date()
    @State private var scheduleArticleLimit = 10
    @State private var loadedSchedule = false
    @State private var isSavingSchedule = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            modePicker
            if mode == .now {
                immediateContent
            } else {
                scheduleContent
            }
            footer
        }
        .padding(24)
        .frame(width: 600)
        .frame(minHeight: 520, alignment: .top)
        .onAppear(perform: loadScheduleOnce)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: SyncVisualStyle.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("同步所有博主文章")
                    .font(.system(size: 20, weight: .bold))
                Text("所有已跟踪博主都会进入队列，已有完整归档自动跳过。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var modePicker: some View {
        Picker("同步方式", selection: $mode) {
            ForEach(Mode.allCases) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .help("选择现在立即同步，或设置每日自动同步")
    }

    private var immediateContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            quantityCard(limit: $articleLimit)
            if !downloadAllArticles {
                totalCountOption
            }
            VStack(alignment: .leading, spacing: 10) {
                SyncInfoRow(
                    symbol: "person.3.fill",
                    title: "全部已跟踪博主",
                    detail: "当前共 \(model.enabledCreatorCount) 位，博主总数不设上限。"
                )
                SyncInfoRow(
                    symbol: "checkmark.circle.fill",
                    title: "已完整归档直接跳过",
                    detail: "只有新文章或未完成文章进入下载队列。"
                )
                SyncInfoRow(
                    symbol: "eye.slash.fill",
                    title: "后台采集，不显示浏览器",
                    detail: "仅读取 X Articles 专属列表，X API 调用为 0。"
                )
            }
            .padding(14)
            .cardBackground()
            readinessRow
        }
    }

    private var totalCountOption: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("同时刷新线上文章总数", isOn: $resolveTotalCount)
                    .help("开启后会完整扫描每位博主的 Articles 列表并更新左侧总数，下载仍只处理最近指定数量")
                Text(resolveTotalCount
                     ? "会完整扫描所有 Articles 列表，等待时间更长，但仍只下载最近 \(articleLimit) 篇。"
                     : "默认只读取最近 \(articleLimit) 篇，速度更快；需要时可在左侧博主菜单中单独刷新总数。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $scheduleEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("每天自动同步")
                            .font(.system(size: 13, weight: .semibold))
                        Text("由 macOS 后台调度，应用窗口关闭时也可自动启动。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .help("启用或关闭每日后台同步")

                Divider()

                LabeledContent {
                    DatePicker(
                        "执行时间",
                        selection: $scheduleTime,
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .disabled(!scheduleEnabled)
                    .help("设置每天自动同步的本地时间")
                } label: {
                    Text("每日执行时间")
                        .font(.system(size: 13, weight: .semibold))
                }

                LabeledContent {
                    compactLimitControl(limit: $scheduleArticleLimit)
                        .disabled(!scheduleEnabled)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("每位博主检查")
                            .font(.system(size: 13, weight: .semibold))
                        Text("当前 \(model.enabledCreatorCount) 位博主会全部同步")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .cardBackground()

            VStack(alignment: .leading, spacing: 10) {
                SyncInfoRow(
                    symbol: "moon.zzz.fill",
                    title: "夜间自动运行",
                    detail: "Mac 睡眠期间错过时间点，macOS 会在下次唤醒后合并补执行一次。"
                )
                SyncInfoRow(
                    symbol: "list.bullet.rectangle",
                    title: "最近执行结果",
                    detail: lastScheduledRunDescription
                )
            }
            .padding(14)
            .cardBackground()

            if scheduleEnabled {
                readinessRow
            }
        }
    }

    private func quantityCard(limit: Binding<Int>) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("每位博主检查的文章数量")
                    .font(.system(size: 13, weight: .semibold))
                Text(downloadAllArticles
                     ? "全部 \(model.enabledCreatorCount) 位博主都会扫描 Articles 列表底部，下载全部可见文章，不受 100 篇限制。"
                     : "全部 \(model.enabledCreatorCount) 位博主，预计最多检查 \(model.enabledCreatorCount * limit.wrappedValue) 篇 X Article。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            compactLimitControl(limit: limit, allowsDownloadAll: true)
        }
        .padding(16)
        .cardBackground()
    }

    private func compactLimitControl(limit: Binding<Int>, allowsDownloadAll: Bool = false) -> some View {
        HStack(spacing: 8) {
            Menu("快捷选择") {
                ForEach([5, 10, 20, 50, 100], id: \.self) { value in
                    Button("最近 \(value) 篇") {
                        if allowsDownloadAll { downloadAllArticles = false }
                        limit.wrappedValue = value
                    }
                        .help("将每位博主的检查范围设为最近 \(value) 篇")
                }
                if allowsDownloadAll {
                    Divider()
                    Button("全部文章") { downloadAllArticles = true }
                        .help("完整扫描每位博主的 Articles 列表，下载全部可见文章")
                }
            }
            .help(allowsDownloadAll
                  ? "快速选择每位博主的文章数量，或改为全部文章"
                  : "快速选择每位博主的文章数量")
            if allowsDownloadAll && downloadAllArticles {
                Text("全部")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 48, alignment: .trailing)
            } else {
                Stepper(value: limit, in: 1...100) {
                    Text("\(limit.wrappedValue) 篇")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .frame(minWidth: 48, alignment: .trailing)
                }
                .fixedSize()
                .help("每位博主检查 1–100 篇 X Article")
            }
        }
    }

    @ViewBuilder
    private var readinessRow: some View {
        if readinessWarning.isEmpty {
            Label("归档目录、Chrome 和媒体存储已就绪", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
        } else {
            Button {
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    model.presentConnectionSetup(focusing: .imageHost)
                }
            } label: {
                Label(readinessWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("关闭同步窗口并直接打开媒体存储配置")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(mode == .now
                 ? (downloadAllArticles
                    ? "全部文章会滚动到每位博主的列表底部，不受 100 篇限制。"
                    : "1–100 是每位博主的文章数，不是博主数。超过 100 篇请选全部文章。")
                 : "完全关机时无法执行；睡眠错过后会在唤醒时补执行。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .help("关闭窗口，不更改定时设置也不开始同步")

            if mode == .now {
                Button("开始后台同步") {
                    model.startSyncAll(
                        articleLimit: downloadAllArticles ? nil : articleLimit,
                        resolveTotalCount: downloadAllArticles || resolveTotalCount
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStartNow)
                .help(canStartNow ? "现在同步所有已跟踪博主" : readinessWarning)
            } else {
                Button(isSavingSchedule ? "正在保存…" : "保存定时设置") {
                    saveSchedule()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSaveSchedule)
                .help(scheduleEnabled
                      ? "保存并注册 macOS 每日后台同步任务"
                      : "关闭并移除 macOS 定时同步任务")
            }
        }
    }

    private var canStartNow: Bool {
        model.enabledCreatorCount > 0 && model.archiveRoot != nil && model.imageHostVerified
    }

    private var canSaveSchedule: Bool {
        !isSavingSchedule && (!scheduleEnabled || canStartNow)
    }

    private var readinessWarning: String {
        if model.archiveRoot == nil { return "本地归档目录未配置，点击前往设置" }
        if !model.imageHostVerified { return "媒体存储未就绪，点击前往配置" }
        if model.enabledCreatorCount == 0 { return "还没有已跟踪博主" }
        return ""
    }

    private var lastScheduledRunDescription: String {
        guard let date = model.scheduledSyncLastRunAt else {
            return model.scheduledSyncLastResult
        }
        return "\(date.formatted(date: .abbreviated, time: .shortened)) · \(model.scheduledSyncLastResult)"
    }

    private func loadScheduleOnce() {
        guard !loadedSchedule else { return }
        loadedSchedule = true
        scheduleEnabled = model.scheduledSyncEnabled
        scheduleArticleLimit = model.scheduledSyncArticleLimit
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = model.scheduledSyncHour
        components.minute = model.scheduledSyncMinute
        scheduleTime = Calendar.current.date(from: components) ?? Date()
    }

    private func saveSchedule() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: scheduleTime)
        isSavingSchedule = true
        Task {
            let success = await model.saveScheduledSync(
                enabled: scheduleEnabled,
                hour: components.hour ?? 2,
                minute: components.minute ?? 0,
                articleLimit: scheduleArticleLimit
            )
            isSavingSchedule = false
            if success { dismiss() }
        }
    }
}

private struct SyncInfoRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 26, height: 26)
                Image(systemName: symbol)
                    .font(.system(size: SyncVisualStyle.iconSize, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 16, height: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private extension View {
    func cardBackground() -> some View {
        background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.75)
        }
    }
}
