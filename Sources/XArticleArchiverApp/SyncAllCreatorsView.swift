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
            MarkXPaneHeader(title: "同步博主文章", onClose: { if !isSavingSchedule { dismiss() } })
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
            MarkXFooter {
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isSavingSchedule)
                    .help("关闭窗口，不启动任务或更改设置")
                if mode == .now {
                    Button("同步 \(model.enabledCreatorCount) 位博主") {
                        model.startSyncAll(articleLimit: downloadAllArticles ? nil : articleLimit,
                            resolveTotalCount: downloadAllArticles || resolveTotalCount)
                    }
                    .buttonStyle(.markxPillProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canStartNow).help(canStartNow ? "开始同步所有已跟踪博主" : readinessWarning)
                } else {
                    Button(isSavingSchedule ? "正在保存…" : "保存设置", action: saveSchedule)
                        .buttonStyle(.markxPillProminent).keyboardShortcut(.defaultAction)
                        .disabled(!canSaveSchedule).help("保存每日同步时间与文章数量")
                }
            }
        }
        .background(MarkXInterface.canvas)
        .font(MarkXFont.body)
        .frame(width: 640, height: MarkXInterface.sheetHeight(620))
        .onAppear(perform: loadScheduleOnce)
        .interactiveDismissDisabled(isSavingSchedule)
    }

    private var immediateContent: some View {
        Group {
            MarkXSection(title: "同步范围") {
                Picker("文章范围", selection: $downloadAllArticles) {
                    Text("最近文章").tag(false)
                    Text("全部文章").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).help("检查最近文章，或完整扫描所有可见文章")
                if !downloadAllArticles {
                    limitRow($articleLimit)
                    Toggle("同时刷新线上文章总数", isOn: $resolveTotalCount)
                        .font(MarkXFont.detail).help("完整扫描列表来刷新总数，下载范围仍为最近指定数量")
                }
            }
        }
    }

    private var scheduleContent: some View {
        Group {
            MarkXSection(title: "每日同步") {
                HStack {
                    Text("自动同步").font(MarkXFont.headline)
                    Spacer()
                    Toggle("自动同步", isOn: $scheduleEnabled)
                        .labelsHidden().toggleStyle(.switch).help("启用或关闭每日后台同步")
                }
                HStack {
                    Text("执行时间")
                    Spacer()
                    DatePicker("执行时间", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                        .labelsHidden().fixedSize().help("设置每天执行同步的本地时间")
                }
                .font(MarkXFont.detail).disabled(!scheduleEnabled)
                limitRow($scheduleArticleLimit).disabled(!scheduleEnabled)
            }
            MarkXSection(title: "最近执行") {
                Text(lastScheduledRunDescription).font(MarkXFont.detail).foregroundStyle(MarkXInterface.text2)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private func limitRow(_ limit: Binding<Int>) -> some View {
        HStack {
            Text("每位博主").font(MarkXFont.detail)
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
        if !readinessWarning.isEmpty {
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
        if model.archiveRoot == nil { return "未选择归档目录" }
        if !model.imageHostVerified { return "媒体存储未就绪" }
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
