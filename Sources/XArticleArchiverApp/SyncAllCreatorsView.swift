import SwiftUI

enum SyncVisualStyle {
    static let symbolName = "arrow.clockwise"
    static let iconSize: CGFloat = 14
}

struct SyncAllCreatorsView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case now, schedule
        var id: String { rawValue }
        var title: String { self == .now ? "立即同步" : "定时同步" }
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
        VStack(spacing: 0) {
            MarkXPaneHeader(title: "同步博主文章", subtitle: "为所有已跟踪博主检查更新，已有完整归档自动跳过。", symbol: SyncVisualStyle.symbolName)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: MarkXInterface.spacing) {
                    Picker("同步方式", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).disabled(isSavingSchedule)
                    .help("现在同步，或设置每天自动同步")
                    if mode == .now { immediateContent } else { scheduleContent }
                    if mode == .now || scheduleEnabled { readinessRow }
                }
                .padding(MarkXInterface.inset)
            }
            MarkXFooter(note: mode == .now ? "当前跟踪 \(model.enabledCreatorCount) 位博主" : "按这台 Mac 的本地时间执行") {
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isSavingSchedule)
                    .help("关闭窗口，不启动任务或更改设置")
                if mode == .now {
                    Button("开始同步") {
                        model.startSyncAll(articleLimit: downloadAllArticles ? nil : articleLimit,
                            resolveTotalCount: downloadAllArticles || resolveTotalCount)
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canStartNow).help(canStartNow ? "开始同步所有已跟踪博主" : readinessWarning)
                } else {
                    Button(isSavingSchedule ? "正在保存…" : "保存设置", action: saveSchedule)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!canSaveSchedule).help("保存每日同步时间与文章数量")
                }
            }
        }
        .background(MarkXInterface.canvas)
        .frame(width: 640, height: MarkXInterface.sheetHeight(620))
        .onAppear(perform: loadScheduleOnce)
        .interactiveDismissDisabled(isSavingSchedule)
    }

    private var immediateContent: some View {
        Group {
            MarkXSection(title: "同步范围", detail: "全部 \(model.enabledCreatorCount) 位博主都会进入同步队列。") {
                Picker("文章范围", selection: $downloadAllArticles) {
                    Text("最近文章").tag(false)
                    Text("全部文章").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).help("检查最近文章，或完整扫描所有可见文章")
                if downloadAllArticles {
                    MarkXInfoLine(symbol: "text.page", text: "扫描到每位博主的列表底部，不受 100 篇限制。")
                } else {
                    limitRow($articleLimit)
                    Divider()
                    Toggle("同时刷新线上文章总数", isOn: $resolveTotalCount)
                        .font(.system(size: 12)).help("完整扫描列表来刷新总数，下载范围仍为最近指定数量")
                    Text(resolveTotalCount ? "将额外扫描完整列表，所需时间更长。" : "优先读取最近文章；总数可以稍后单独刷新。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            MarkXSection(title: "执行方式") {
                MarkXInfoLine(symbol: "checkmark.circle", text: "跳过已有完整归档，只保存新文章和未完成文章。")
                MarkXInfoLine(symbol: "rectangle.on.rectangle", text: "在后台运行，关闭进度窗口后任务仍会继续。")
            }
        }
    }

    private var scheduleContent: some View {
        Group {
            MarkXSection(title: "每日同步") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自动同步").font(.system(size: 13, weight: .medium))
                        Text("每天为所有已跟踪博主检查更新").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("自动同步", isOn: $scheduleEnabled)
                        .labelsHidden().toggleStyle(.switch).help("启用或关闭每日后台同步")
                }
                Divider()
                HStack {
                    Text("执行时间")
                    Spacer()
                    DatePicker("执行时间", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                        .labelsHidden().fixedSize().help("设置每天执行同步的本地时间")
                }
                .font(.system(size: 12)).disabled(!scheduleEnabled)
                limitRow($scheduleArticleLimit).disabled(!scheduleEnabled)
            }
            MarkXSection(title: "最近执行") {
                Text(lastScheduledRunDescription).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Divider()
                MarkXInfoLine(symbol: "moon", text: "睡眠期间错过的任务会在唤醒后补执行；关机时无法运行。")
            }
        }
    }

    private func limitRow(_ limit: Binding<Int>) -> some View {
        HStack {
            Text("每位博主").font(.system(size: 12))
            Spacer()
            Menu("预设") {
                ForEach([5, 10, 20, 50, 100], id: \.self) { value in
                    Button("最近 \(value) 篇") { limit.wrappedValue = value }
                }
            }
            .fixedSize().help("快速选择每位博主的检查数量")
            Stepper(value: limit, in: 1...100) {
                Text("\(limit.wrappedValue) 篇").monospacedDigit().frame(minWidth: 44, alignment: .trailing)
            }
            .fixedSize().help("每位博主检查最近 1–100 篇文章")
        }
    }

    @ViewBuilder private var readinessRow: some View {
        if readinessWarning.isEmpty {
            MarkXInfoLine(symbol: "checkmark.circle", text: "归档位置与媒体存储已就绪", color: .green)
        } else {
            Button {
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    model.presentConnectionSetup(focusing: .imageHost)
                }
            } label: {
                MarkXInfoLine(symbol: "exclamationmark.circle", text: readinessWarning, color: .orange)
            }
            .buttonStyle(.plain).help("前往连接与存储配置")
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
